(* Translation *)

open Semant;;
open Common;;

let log cx = Session.log "trans"
  cx.ctxt_sess.Session.sess_log_trans
  cx.ctxt_sess.Session.sess_log_out
;;

let arr_max a = (Array.length a) - 1;;

type quad_idx = int
;;

type mem_ctrl =
    MEM_rc_opaque of int
  | MEM_rc_struct
  | MEM_gc
  | MEM_interior

type clone_ctrl =
    CLONE_none
  | CLONE_chan of Il.cell
  | CLONE_all of Il.cell

type call_ctrl =
    CALL_direct
  | CALL_vtbl
  | CALL_indirect

type foreach_ctrl =
    {
      foreach_fixup: fixup;
      foreach_depth: int;
    }
;;

type call =
    {
      call_ctrl: call_ctrl;
      call_callee_ptr: Il.operand;
      call_callee_ty: Ast.ty;
      call_callee_ty_params: Ast.ty array;
      call_output: Il.cell;
      call_args: Ast.atom array;
      call_iterator_args: Il.operand array;
      call_indirect_args: Il.operand array;
    }
;;

let trans_visitor
    (cx:ctxt)
    (path:Ast.name_component Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =

  let iflog thunk =
    if cx.ctxt_sess.Session.sess_log_trans
    then thunk ()
    else ()
  in

  let curr_file = Stack.create () in
  let curr_stmt = ref None in

  let (abi:Abi.abi) = cx.ctxt_abi in
  let (word_sz:int64) = abi.Abi.abi_word_sz in
  let (word_bits:Il.bits) = abi.Abi.abi_word_bits in
  let (word_ty:Il.scalar_ty) = Il.ValTy word_bits in
  let (word_rty:Il.referent_ty) = Il.ScalarTy word_ty in
  let (word_ty_mach:ty_mach) =
    match word_bits with
        Il.Bits8 -> TY_u8
      | Il.Bits16 -> TY_u16
      | Il.Bits32 -> TY_u32
      | Il.Bits64 -> TY_u64
  in
  let (word_ty_signed_mach:ty_mach) =
    match word_bits with
        Il.Bits8 -> TY_s8
      | Il.Bits16 -> TY_s16
      | Il.Bits32 -> TY_s32
      | Il.Bits64 -> TY_s64
  in
  let (word_slot:Ast.slot) = word_slot abi in
  let word_n (n:int) = Int64.mul word_sz (Int64.of_int n) in
  let exterior_rc_body_off : int64 = word_n Abi.exterior_rc_slot_field_body in
  let exterior_gc_body_off : int64 = word_n Abi.exterior_gc_slot_field_body in


  let imm_of_ty (i:int64) (tm:ty_mach) : Il.operand =
    Il.Imm (Asm.IMM i, tm)
  in

  let imm (i:int64) : Il.operand = imm_of_ty i word_ty_mach in
  let simm (i:int64) : Il.operand = imm_of_ty i word_ty_signed_mach in
  let marker = imm 0xdeadbeefL in
  let one = imm 1L in
  let zero = imm 0L in
  let imm_true = imm_of_ty 1L TY_u8 in
  let imm_false = imm_of_ty 0L TY_u8 in
  let nil_ptr = Il.Mem ((Il.Abs (Asm.IMM 0L)), Il.NilTy) in

  let crate_rel fix =
    Asm.SUB (Asm.M_POS fix, Asm.M_POS cx.ctxt_crate_fixup)
  in

  let crate_rel_word fix =
    Asm.WORD (word_ty_signed_mach, crate_rel fix)
  in

  let crate_rel_imm (fix:fixup) : Il.operand =
    Il.Imm (crate_rel fix, word_ty_signed_mach)
  in

  let table_of_crate_rel_fixups (fixups:fixup array) : Asm.frag =
    Asm.SEQ (Array.map crate_rel_word fixups)
  in

  let nabi_indirect =
      match cx.ctxt_sess.Session.sess_targ with
          Linux_x86_elf -> false
        | _ -> true
  in

  let nabi_rust =
    { nabi_indirect = nabi_indirect;
      nabi_convention = CONV_rust }
  in

  let out_mem_disp = abi.Abi.abi_frame_base_sz in
  let arg0_disp =
    Int64.add abi.Abi.abi_frame_base_sz abi.Abi.abi_implicit_args_sz
  in
  let frame_crate_ptr = word_n (-1) in
  let frame_fns_disp = word_n (-2) in

  let fn_ty (id:node_id) : Ast.ty =
    Hashtbl.find cx.ctxt_all_item_types id
  in
  let fn_args_rty
      (id:node_id)
      (closure:Il.referent_ty option)
      : Il.referent_ty =
    call_args_referent_type cx (n_item_ty_params cx id) (fn_ty id) closure
  in

  let (fns:node_id Stack.t) = Stack.create () in
  let current_fn () = Stack.top fns in
  let current_fn_args_rty (closure:Il.referent_ty option) : Il.referent_ty =
    fn_args_rty (current_fn()) closure
  in
  let current_fn_callsz () = get_callsz cx (current_fn()) in

  let emitters = Stack.create () in
  let push_new_emitter (vregs_ok:bool) =
    Stack.push
      (Il.new_emitter
         abi.Abi.abi_prealloc_quad
         abi.Abi.abi_is_2addr_machine
         vregs_ok)
      emitters
  in

  let push_new_emitter_with_vregs _ = push_new_emitter true in
  let push_new_emitter_without_vregs _ = push_new_emitter false in

  let pop_emitter _ = ignore (Stack.pop emitters) in
  let emitter _ = Stack.top emitters in
  let emit q = Il.emit (emitter()) q in
  let next_vreg _ = Il.next_vreg (emitter()) in
  let next_vreg_cell t = Il.next_vreg_cell (emitter()) t in
  let mark _ : quad_idx = (emitter()).Il.emit_pc in
  let patch_existing (jmp:quad_idx) (targ:quad_idx) : unit =
    Il.patch_jump (emitter()) jmp targ
  in
  let patch (i:quad_idx) : unit =
    Il.patch_jump (emitter()) i (mark());
    (* Insert a dead quad to ensure there's an otherwise-unused
     * jump-target here.
     *)
    emit Il.Dead
  in

  let annotations _ =
    (emitter()).Il.emit_annotations
  in

  let annotate (str:string) =
    let e = emitter() in
      Hashtbl.add e.Il.emit_annotations e.Il.emit_pc str
  in

  let epilogue_jumps = Stack.create() in

  let path_name (_:unit) : string =
    string_of_name (Walk.path_to_name path)
  in

  let based (reg:Il.reg) : Il.mem =
    Il.RegIn (reg, None)
  in

  let based_off (reg:Il.reg) (off:Asm.expr64) : Il.mem =
    Il.RegIn (reg, Some off)
  in

  let based_imm (reg:Il.reg) (imm:int64) : Il.mem =
    based_off reg (Asm.IMM imm)
  in

  let fp_imm (imm:int64) : Il.mem =
    based_imm abi.Abi.abi_fp_reg imm
  in

  let sp_imm (imm:int64) : Il.mem =
    based_imm abi.Abi.abi_sp_reg imm
  in

  let word_at (mem:Il.mem) : Il.cell =
    Il.Mem (mem, Il.ScalarTy (Il.ValTy word_bits))
  in

  let wordptr_at (mem:Il.mem) : Il.cell =
    Il.Mem (mem, Il.ScalarTy (Il.AddrTy (Il.ScalarTy (Il.ValTy word_bits))))
  in

  let mov (dst:Il.cell) (src:Il.operand) : unit =
    emit (Il.umov dst src)
  in

  let lea (dst:Il.cell) (src:Il.mem) : unit =
    emit (Il.lea dst (Il.Cell (Il.Mem (src, Il.OpaqueTy))))
  in

  let rty_ptr_at (mem:Il.mem) (pointee_rty:Il.referent_ty) : Il.cell =
    Il.Mem (mem, Il.ScalarTy (Il.AddrTy pointee_rty))
  in

  let ptr_at (mem:Il.mem) (pointee_ty:Ast.ty) : Il.cell =
    rty_ptr_at mem (referent_type abi pointee_ty)
  in

  let need_scalar_ty (rty:Il.referent_ty) : Il.scalar_ty =
    match rty with
        Il.ScalarTy s -> s
      | _ -> bug () "expected ScalarTy"
  in

  let need_mem_cell (cell:Il.cell) : Il.typed_mem =
    match cell with
        Il.Mem a -> a
      | Il.Reg _ -> bug ()
          "expected address cell, got non-address register cell"
  in

  let need_cell (operand:Il.operand) : Il.cell =
    match operand with
        Il.Cell c -> c
      | _ -> bug () "expected cell, got operand %s"
          (Il.string_of_operand  abi.Abi.abi_str_of_hardreg operand)
  in

  let get_element_ptr = Il.get_element_ptr word_bits abi.Abi.abi_str_of_hardreg in

  let get_variant_ptr (mem_cell:Il.cell) (i:int) : Il.cell =
    match mem_cell with
        Il.Mem (mem, Il.UnionTy elts) when i >= 0 && i < (Array.length elts) ->
          assert ((Array.length elts) != 0);
          Il.Mem (mem, elts.(i))

      | _ -> bug () "get_variant_ptr %d on cell %s" i
          (Il.string_of_cell abi.Abi.abi_str_of_hardreg mem_cell)
  in

  let rec ptr_cast (cell:Il.cell) (rty:Il.referent_ty) : Il.cell =
    match cell with
        Il.Mem (mem, _) -> Il.Mem (mem, rty)
      | Il.Reg (reg, Il.AddrTy _) -> Il.Reg (reg, Il.AddrTy rty)
      | _ -> bug () "expected address cell in Trans.ptr_cast"

  and curr_crate_ptr _ : Il.cell =
    word_at (fp_imm frame_crate_ptr)

  and crate_rel_to_ptr (rel:Il.operand) (rty:Il.referent_ty) : Il.cell =
    let cell = next_vreg_cell (Il.AddrTy rty) in
      mov cell (Il.Cell (curr_crate_ptr()));
      emit (Il.binary Il.ADD cell (Il.Cell cell) rel);
      cell

  (* 
   * Note: alias *requires* its cell to be in memory already, and should
   * only be used on slots you know to be memory-resident. Use 'aliasing' or 
   * 'via_memory' if you have a cell or operand you want in memory for a very
   * short period of time (the time spent by the code generated by the thunk).
   *)

  and alias (cell:Il.cell) : Il.cell =
    let mem, ty = need_mem_cell cell in
    let vreg_cell = next_vreg_cell (Il.AddrTy ty) in
      begin
        match ty with
            Il.NilTy -> ()
          | _ -> lea vreg_cell mem
      end;
      vreg_cell

  and force_to_mem (src:Il.operand) : Il.typed_mem =
    let do_spill op (t:Il.scalar_ty) =
      let s = (Il.next_spill (emitter())) in
      let spill_mem = Il.Spill s in
      let spill_ta = (spill_mem, Il.ScalarTy t) in
        mov (Il.Mem spill_ta) op;
        spill_ta
    in
    match src with
        Il.Cell (Il.Mem ta) -> ta
      | Il.Cell (Il.Reg (_, t)) -> do_spill src t
      | Il.Imm _ -> do_spill src (Il.ValTy word_bits)
      | Il.ImmPtr (f, rty) ->
          do_spill
            (Il.Cell (crate_rel_to_ptr (crate_rel_imm f) rty))
            (Il.AddrTy rty)

  and force_to_reg (op:Il.operand) : Il.typed_reg =
    let do_mov op st =
      let tmp = next_vreg () in
      let regty = (tmp, st) in
        mov (Il.Reg regty) op;
        regty
    in
      match op with
          Il.Imm  (_, tm) -> do_mov op (Il.ValTy (Il.bits_of_ty_mach tm))
        | Il.ImmPtr (f, rty) ->
            do_mov
              (Il.Cell (crate_rel_to_ptr (crate_rel_imm f) rty))
              (Il.AddrTy rty)
        | Il.Cell (Il.Reg rt) -> rt
        | Il.Cell (Il.Mem (_, Il.ScalarTy st)) -> do_mov op st
        | Il.Cell (Il.Mem (_, rt)) ->
            bug () "forcing non-scalar referent of type %s to register"
              (Il.string_of_referent_ty rt)

  and via_memory (writeback:bool) (c:Il.cell) (thunk:Il.cell -> unit) : unit =
    match c with
        Il.Mem _ -> thunk c
      | Il.Reg _ ->
          let mem_c = Il.Mem (force_to_mem (Il.Cell c)) in
            thunk mem_c;
            if writeback
            then
              mov c (Il.Cell mem_c)

  and aliasing (writeback:bool) (c:Il.cell) (thunk:Il.cell -> unit) : unit =
    via_memory writeback c (fun c -> thunk (alias c))

  and pointee_type (ptr:Il.cell) : Il.referent_ty =
    match ptr with
        Il.Reg (_, (Il.AddrTy rt)) -> rt
      | Il.Mem (_, Il.ScalarTy (Il.AddrTy rt)) -> rt
      | _ ->
          bug () "taking pointee-type of non-address cell %s "
            (Il.string_of_cell abi.Abi.abi_str_of_hardreg ptr)

  and deref (ptr:Il.cell) : Il.cell =
    let (r, st) = force_to_reg (Il.Cell ptr) in
      match st with
          Il.AddrTy rt -> Il.Mem (based r, rt)
        | _ -> bug () "dereferencing non-address cell of type %s "
            (Il.string_of_scalar_ty st)

  and deref_off (ptr:Il.cell) (off:Asm.expr64) : Il.cell =
    let (r, st) = force_to_reg (Il.Cell ptr) in
      match st with
          Il.AddrTy rt -> Il.Mem (based_off r off, rt)
        | _ -> bug () "offset-dereferencing non-address cell of type %s "
            (Il.string_of_scalar_ty st)

  and deref_imm (ptr:Il.cell) (imm:int64) : Il.cell =
    deref_off ptr (Asm.IMM imm)

  and tp_imm (imm:int64) : Il.cell =
    deref_imm abi.Abi.abi_tp_cell imm
  in

  let cell_vreg_num (vr:(int option) ref) : int =
    match !vr with
        None ->
          let v = (Il.next_vreg_num (emitter())) in
            vr := Some v;
            v
      | Some v -> v
  in

  let slot_id_referent_type (slot_id:node_id) : Il.referent_ty =
    slot_referent_type abi (referent_to_slot cx slot_id)
  in

  let get_ty_desc (fp:Il.reg) (fn:node_id) (param_idx:int) : Il.cell =
    let args_cell =
      Il.Mem (based_imm fp out_mem_disp, (fn_args_rty fn None))
    in
    let ty_params = get_element_ptr args_cell Abi.calltup_elt_ty_params in
      deref (get_element_ptr ty_params param_idx)
  in

  let get_current_fn_ty_desc (param_idx:int) : Il.cell =
    get_ty_desc abi.Abi.abi_fp_reg (current_fn()) param_idx
  in

  let rec calculate_sz (fp:Il.reg) (fn:node_id) (size:size) : Il.operand =
    iflog (fun _ -> annotate
             (Printf.sprintf "calculating size %s"
                (string_of_size size)));
    let res =
      match size with
          SIZE_fixed i -> imm i
        | SIZE_fixup_mem_pos f -> Il.Imm (Asm.M_POS f, word_ty_mach)
        | SIZE_fixup_mem_sz f -> Il.Imm (Asm.M_SZ f, word_ty_mach)

        | SIZE_param_size i ->
            let ty_desc = get_ty_desc fp fn i in
              Il.Cell (get_element_ptr ty_desc Abi.tydesc_field_size)

        | SIZE_param_align i ->
            let ty_desc = get_ty_desc fp fn i in
              Il.Cell (get_element_ptr ty_desc Abi.tydesc_field_align)

        | SIZE_rt_neg a ->
            let op_a = calculate_sz fp fn a in
            let tmp = next_vreg_cell word_ty in
              emit (Il.unary Il.NEG tmp op_a);
              Il.Cell tmp

        | SIZE_rt_add (a, b) ->
            let op_a = calculate_sz fp fn a in
            let op_b = calculate_sz fp fn b in
            let tmp = next_vreg_cell word_ty in
              emit (Il.binary Il.ADD tmp op_a op_b);
              Il.Cell tmp

        | SIZE_rt_mul (a, b) ->
            let op_a = calculate_sz fp fn a in
            let op_b = calculate_sz fp fn b in
            let tmp = next_vreg_cell word_ty in
              emit (Il.binary Il.UMUL tmp op_a op_b);
              Il.Cell tmp

        | SIZE_rt_max (a, b) ->
            let op_a = calculate_sz fp fn a in
            let op_b = calculate_sz fp fn b in
            let tmp = next_vreg_cell word_ty in
              mov tmp op_a;
              emit (Il.cmp op_a op_b);
              let jmp = mark () in
                emit (Il.jmp Il.JAE Il.CodeNone);
                mov tmp op_b;
                patch jmp;
                Il.Cell tmp

        | SIZE_rt_align (align, off) ->
            (*
             * calculate off + pad where:
             *
             * pad = (align - (off mod align)) mod align
             *
             *)
            annotate "fetch alignment";
            let op_align = calculate_sz fp fn align in
              annotate "fetch offset";
              let op_off = calculate_sz fp fn off in
              let t1 = next_vreg_cell word_ty in
              let t2 = next_vreg_cell word_ty in
              let t3 = next_vreg_cell word_ty in
              let t4 = next_vreg_cell word_ty in
                annotate "tmp = off % align";
                emit (Il.binary Il.UMOD t1 op_off op_align);
                annotate "tmp = align - tmp";
                emit (Il.binary Il.SUB t2 op_align (Il.Cell t1));
                annotate "tmp = tmp % align";
                emit (Il.binary Il.UMOD t3 (Il.Cell t2) op_align);
                annotate "tmp = tmp + off";
                emit (Il.binary Il.ADD t4 (Il.Cell t3) op_off);
                Il.Cell t4
    in
      iflog (fun _ -> annotate
               (Printf.sprintf "calculated size %s is %s"
                  (string_of_size size)
                  (Il.string_of_operand abi.Abi.abi_str_of_hardreg res)));
      res


  and calculate_sz_in_current_frame (size:size) : Il.operand =
    calculate_sz abi.Abi.abi_fp_reg (current_fn()) size

  and caller_args_cell (args_rty:Il.referent_ty) : Il.cell =
    Il.Mem (fp_imm out_mem_disp, args_rty)

  and callee_args_cell (tail_area:bool) (args_rty:Il.referent_ty) : Il.cell =
    if tail_area
    then
      Il.Mem (sp_off_sz (current_fn_callsz ()), args_rty)
    else
      Il.Mem (sp_imm 0L, args_rty)

  and based_sz (fp:Il.reg) (fn:node_id) (reg:Il.reg) (size:size) : Il.mem =
    match Il.size_to_expr64 size with
        Some e -> based_off reg e
      | None ->
             let runtime_size = calculate_sz fp fn size in
             let v = next_vreg () in
             let c = (Il.Reg (v, word_ty)) in
               mov c (Il.Cell (Il.Reg (reg, word_ty)));
               emit (Il.binary Il.ADD c (Il.Cell c) runtime_size);
               based v

  and fp_off_sz (size:size) : Il.mem =
    based_sz abi.Abi.abi_fp_reg (current_fn()) abi.Abi.abi_fp_reg size

  and sp_off_sz (size:size) : Il.mem =
    based_sz abi.Abi.abi_fp_reg (current_fn()) abi.Abi.abi_sp_reg size
  in

  let deref_off_sz
      (fp:Il.reg)
      (fn:node_id)
      (ptr:Il.cell)
      (size:size)
      : Il.cell =
    match Il.size_to_expr64 size with
        Some e -> deref_off ptr e
      | None ->
          let runtime_size = calculate_sz fp fn size in
          let v = next_vreg () in
          let c = (Il.Reg (v, word_ty)) in
            mov c (Il.Cell ptr);
            emit (Il.binary Il.ADD c (Il.Cell c) runtime_size);
            Il.Mem (based v, (pointee_type ptr))
  in

  let cell_of_block_slot
      (slot_id:node_id)
      : Il.cell =
    let referent_type = slot_id_referent_type slot_id in
      match htab_search cx.ctxt_slot_vregs slot_id with
          Some vr ->
            begin
              match referent_type with
                  Il.ScalarTy st -> Il.Reg (Il.Vreg (cell_vreg_num vr), st)
                | Il.NilTy -> nil_ptr
                | Il.StructTy _ -> bugi cx slot_id
                    "cannot treat structured referent as single operand"
                | Il.UnionTy _ -> bugi cx slot_id
                    "cannot treat union referent as single operand"
                | Il.ParamTy _ -> bugi cx slot_id
                    "cannot treat parametric referent as single operand"
                | Il.OpaqueTy -> bugi cx slot_id
                    "cannot treat opaque referent as single operand"
                | Il.CodeTy ->  bugi cx slot_id
                    "cannot treat code referent as single operand"
            end
        | None ->
            begin
              match htab_search cx.ctxt_slot_offsets slot_id with
                  None -> bugi cx slot_id
                    "slot assigned to neither vreg nor offset"
                | Some off ->
                    if slot_is_obj_state cx slot_id
                    then
                      begin
                        let curr_args_rty =
                          current_fn_args_rty (Some Il.OpaqueTy)
                        in
                        let self_args_cell =
                          caller_args_cell curr_args_rty
                        in
                        let self_indirect_args =
                          get_element_ptr self_args_cell
                            Abi.calltup_elt_indirect_args
                        in
                        let state_arg =
                          get_element_ptr self_indirect_args
                            Abi.indirect_args_elt_closure
                        in
                        let (slot_mem, _) =
                          need_mem_cell (deref_imm state_arg (force_sz off))
                        in
                          Il.Mem (slot_mem, referent_type)
                      end
                    else Il.Mem (fp_off_sz off, referent_type)
            end
  in

  let iter_block_slots
      (block_id:node_id)
      (fn:Ast.slot_key -> node_id -> Ast.slot -> unit)
      : unit =
    let block_slots = Hashtbl.find cx.ctxt_block_slots block_id in
      Hashtbl.iter
        begin
          fun key slot_id ->
            let slot = referent_to_slot cx slot_id in
              fn key slot_id slot
        end
        block_slots

  in

  let iter_frame_slots
      (frame_id:node_id)
      (fn:Ast.slot_key -> node_id -> Ast.slot -> unit)
      : unit =
    let blocks = Hashtbl.find cx.ctxt_frame_blocks frame_id in
      List.iter (fun block -> iter_block_slots block fn) blocks
  in

  let iter_frame_and_arg_slots
      (frame_id:node_id)
      (fn:Ast.slot_key -> node_id -> Ast.slot -> unit)
      : unit =
    iter_frame_slots frame_id fn;
    match htab_search cx.ctxt_frame_args frame_id with
        None -> ()
      | Some ls ->
          List.iter
            begin
              fun slot_id ->
                let key = Hashtbl.find cx.ctxt_slot_keys slot_id in
                let slot = referent_to_slot cx slot_id in
                  fn key slot_id slot
            end
            ls
  in

  let binop_to_jmpop (binop:Ast.binop) : Il.jmpop =
    match binop with
        Ast.BINOP_eq -> Il.JE
      | Ast.BINOP_ne -> Il.JNE
      | Ast.BINOP_lt -> Il.JL
      | Ast.BINOP_le -> Il.JLE
      | Ast.BINOP_ge -> Il.JGE
      | Ast.BINOP_gt -> Il.JG
      | _ -> bug () "Unhandled binop in binop_to_jmpop"
  in

  let rec trans_slot_lval_ext
      (base_ty:Ast.ty)
      (cell:Il.cell)
      (comp:Ast.lval_component)
      : (Il.cell * Ast.slot) =

    let bounds_checked_access at slot =
      let atop = trans_atom at in
      let unit_sz = slot_sz abi slot in
      let idx = next_vreg_cell word_ty in
        emit (Il.binary Il.UMUL idx atop (imm unit_sz));
        let elt_mem = trans_bounds_check (deref cell) (Il.Cell idx) in
          (Il.Mem (elt_mem, slot_referent_type abi slot), slot)
    in

    match (base_ty, comp) with
        (Ast.TY_rec entries,
         Ast.COMP_named (Ast.COMP_ident id)) ->
          let i = arr_idx (Array.map fst entries) id in
            (get_element_ptr cell i, snd entries.(i))

      | (Ast.TY_tup entries,
         Ast.COMP_named (Ast.COMP_idx i)) ->
          (get_element_ptr cell i, entries.(i))

      | (Ast.TY_vec slot,
         Ast.COMP_atom at) ->
          bounds_checked_access at slot

      | (Ast.TY_str,
         Ast.COMP_atom at) ->
          bounds_checked_access at (interior_slot (Ast.TY_mach TY_u8))

      | (Ast.TY_obj fns,
         Ast.COMP_named (Ast.COMP_ident id)) ->

          let sorted_idents = sorted_htab_keys fns in
          let i = arr_idx sorted_idents id in
          let fn_ty = Hashtbl.find fns id in
          let (table_mem, _) = (need_mem_cell (deref (get_element_ptr cell Abi.binding_field_item))) in
          let callee_disp = Il.Cell (word_at (Il.mem_off_imm table_mem (word_n i))) in
            (crate_rel_to_ptr callee_disp Il.CodeTy, interior_slot (Ast.TY_fn fn_ty))


      | _ -> bug () "unhandled form of lval_ext in trans_slot_lval_ext"

  (* 
   * vec: operand holding ptr to vec.
   * mul_idx: index value * unit size.
   * return: ptr to element.
   *)
  and trans_bounds_check (vec:Il.cell) (mul_idx:Il.operand) : Il.mem =
    let (len:Il.cell) = get_element_ptr vec Abi.vec_elt_fill in
    let (data:Il.cell) = get_element_ptr vec Abi.vec_elt_data in
    let (base:Il.cell) = next_vreg_cell Il.voidptr_t in
    let (elt_reg:Il.reg) = next_vreg () in
    let (elt:Il.cell) = Il.Reg (elt_reg, Il.voidptr_t) in
    let (diff:Il.cell) = next_vreg_cell word_ty in
      annotate "bounds check";
      lea base (fst (need_mem_cell data));
      emit (Il.binary Il.ADD elt (Il.Cell base) mul_idx);
      emit (Il.binary Il.SUB diff (Il.Cell elt) (Il.Cell base));
      let jmp = trans_compare Il.JB (Il.Cell diff) (Il.Cell len) in
        trans_cond_fail "bounds check" jmp;
        based elt_reg

  and trans_lval_full
      (initializing:bool)
      (lv:Ast.lval)
      : (Il.cell * Ast.slot) =

    let rec trans_slot_lval_full (initializing:bool) lv =
      match lv with
          Ast.LVAL_ext (base, comp) ->
            let (base_cell, base_slot) =
              trans_slot_lval_full initializing base
            in
            let base_cell' = deref_slot initializing base_cell base_slot in
              trans_slot_lval_ext (slot_ty base_slot) base_cell' comp

        | Ast.LVAL_base nb ->
            let slot = lval_to_slot cx nb.id in
            let referent = lval_to_referent cx nb.id in
            let cell = cell_of_block_slot referent in
              (cell, slot)
    in
      if lval_is_slot cx lv
      then trans_slot_lval_full initializing lv
      else
        if initializing
        then err None "init item"
        else
          begin
            assert (lval_is_item cx lv);
            bug ()
              "trans_lval_full called on item lval '%a'" Ast.sprintf_lval lv
          end

  and trans_lval_maybe_init
      (initializing:bool)
      (lv:Ast.lval)
      : (Il.cell * Ast.slot) =
    trans_lval_full initializing lv

  and trans_lval_init (lv:Ast.lval) : (Il.cell * Ast.slot) =
    trans_lval_maybe_init true lv

  and trans_lval (lv:Ast.lval) : (Il.cell * Ast.slot) =
    trans_lval_maybe_init false lv

  and trans_callee
      (flv:Ast.lval)
      : (Il.operand * Ast.ty) =
    (* direct call to item *)
    let fty = Hashtbl.find cx.ctxt_all_lval_types (lval_base_id flv) in
      if lval_is_item cx flv then
        let fn_item = lval_item cx flv in
        let fn_ptr = code_fixup_to_ptr_operand (get_fn_fixup cx fn_item.id) in
          (fn_ptr, fty)
      else
        (* indirect call to computed slot *)
        let (cell, _) = trans_lval flv in
          (Il.Cell cell, fty)

  and trans_crate_rel_data_operand
      (d:data)
      (thunk:unit -> Asm.frag)
      : Il.operand =
    let (fix, _) =
      htab_search_or_add cx.ctxt_data d
        begin
          fun _ ->
            let fix = new_fixup "data item" in
            let frag = Asm.DEF (fix, thunk()) in
              (fix, frag)
        end
    in
      crate_rel_imm fix

  and trans_crate_rel_data_frag (d:data) (thunk:unit -> Asm.frag) : Asm.frag =
    let (fix, _) =
      htab_search_or_add cx.ctxt_data d
        begin
          fun _ ->
            let fix = new_fixup "data item" in
            let frag = Asm.DEF (fix, thunk()) in
              (fix, frag)
        end
    in
      crate_rel_word fix

  and trans_crate_rel_static_string_operand (s:string) : Il.operand =
    trans_crate_rel_data_operand (DATA_str s) (fun _ -> Asm.ZSTRING s)

  and trans_crate_rel_static_string_frag (s:string) : Asm.frag =
    trans_crate_rel_data_frag (DATA_str s) (fun _ -> Asm.ZSTRING s)

  and trans_static_string (s:string) : Il.operand =
    Il.Cell (crate_rel_to_ptr
               (trans_crate_rel_static_string_operand s)
               (referent_type abi Ast.TY_str))

  and trans_tydesc (t:Ast.ty) : Il.operand =
    trans_crate_rel_data_operand
      (DATA_tydesc t)
      begin
        fun _ ->
          Asm.SEQ
            [|
              Asm.WORD (word_ty_mach, Asm.IMM (ty_sz abi t));
              Asm.WORD (word_ty_mach, Asm.IMM (ty_align abi t));
              table_of_crate_rel_fixups
                [|
                  get_copy_glue t None;
                  get_drop_glue t None;
                  get_free_glue t (slot_mem_ctrl (interior_slot t)) None;
                |]
            |]
      end

  and trans_obj_vtbl (id:node_id) : Il.operand =
    let obj =
      match Hashtbl.find cx.ctxt_all_defns id with
          DEFN_item { Ast.decl_item=Ast.MOD_ITEM_obj obj} -> obj
        | _ -> bug () "Trans.trans_obj_vtbl on non-obj referent"
    in
      trans_crate_rel_data_operand (DATA_obj_vtbl id)
        begin
          fun _ ->
            iflog (fun _ -> log cx "emitting %d-entry obj vtbl for %s"
                     (Hashtbl.length obj.Ast.obj_fns) (path_name()));
            let fptrs =
              Array.map
                begin
                  fun k ->
                    let fn = Hashtbl.find obj.Ast.obj_fns k in
                    let fix = get_fn_fixup cx fn.id in
                      crate_rel_word fix
                end
                (sorted_htab_keys obj.Ast.obj_fns)
            in
              Asm.SEQ fptrs
        end

  and trans_init_str (dst:Ast.lval) (s:string) : unit =
    (* Include null byte. *)
    let init_sz = Int64.of_int ((String.length s) + 1) in
    let static = trans_static_string s in
    let (dst, _) = trans_lval_init dst in
      trans_upcall "upcall_new_str" dst [| static; imm init_sz |]

  and trans_atom (atom:Ast.atom) : Il.operand =
    iflog
      begin
        fun _ ->
          annotate (Ast.fmt_to_str Ast.fmt_atom atom)
      end;

    match atom with
        Ast.ATOM_lval lv ->
          let (cell, slot) = trans_lval lv in
            Il.Cell (deref_slot false cell slot)

      | Ast.ATOM_literal lit ->
          begin
            match lit.node with
                Ast.LIT_nil -> Il.Cell (nil_ptr)
              | Ast.LIT_bool false -> imm_false
              | Ast.LIT_bool true -> imm_true
              | Ast.LIT_char c -> imm_of_ty (Int64.of_int (Char.code c)) TY_u32
              | Ast.LIT_int (i, _) -> simm i
              | Ast.LIT_uint (i, _) -> imm i
              | Ast.LIT_mach (m, n, _) -> imm_of_ty n m

              | _ -> marker
          end

  and fixup_to_ptr_operand
      (imm_ok:bool)
      (fix:fixup)
      (referent_ty:Il.referent_ty)
      : Il.operand =
    if imm_ok
    then Il.ImmPtr (fix, referent_ty)
    else Il.Cell (crate_rel_to_ptr (crate_rel_imm fix) referent_ty)

  and code_fixup_to_ptr_operand (fix:fixup) : Il.operand =
    fixup_to_ptr_operand abi.Abi.abi_has_pcrel_code fix Il.CodeTy

  and fixup_to_code (fix:fixup) : Il.code =
    code_of_operand (code_fixup_to_ptr_operand fix)

  (* A pointer-valued op may be of the form ImmPtr, which carries its
   * target fixup, "constant-propagated" through trans so that
   * pc-relative addressing can make use of it whenever
   * appropriate. Reify_ptr exists for cases when you are about to
   * store an ImmPtr into a memory cell or other place beyond which the
   * compiler will cease to know about its identity; at this point you
   * should decay it to a crate-relative displacement and
   * (computationally) add it to the crate base value, before working
   * with it.
   * 
   * This helps you obey the IL type-system prohibition against
   * 'mov'-ing an ImmPtr to a cell. If you forget to call this
   * in the right places, you will get code-generation failures.
   *)
  and reify_ptr (op:Il.operand) : Il.operand =
    match op with
        Il.ImmPtr (fix, rty) ->
          Il.Cell (crate_rel_to_ptr (crate_rel_imm fix) rty)
      | _ -> op

  and annotate_quads (name:string) : unit =
    let e = emitter() in
    let quads = emitted_quads e in
    let annotations = annotations() in
      log cx "emitted quads for %s:" name;
      for i = 0 to arr_max quads
      do
        if Hashtbl.mem annotations i
        then
          List.iter
            (fun a -> log cx "// %s" a)
            (List.rev (Hashtbl.find_all annotations i));
        log cx "[%6d]\t%s" i
          (Il.string_of_quad
             abi.Abi.abi_str_of_hardreg quads.(i));
      done


  and write_frame_info_ptrs (fnid:node_id option) =
    let frame_fns =
      match fnid with
          None -> zero
        | Some fnid -> get_frame_glue_fns fnid
    in
    let crate_ptr_reg = next_vreg () in
    let crate_ptr_cell = Il.Reg (crate_ptr_reg, (Il.AddrTy Il.OpaqueTy)) in
      iflog (fun _ -> annotate "write frame-info pointers");
      Abi.load_fixup_addr (emitter())
        crate_ptr_reg cx.ctxt_crate_fixup Il.OpaqueTy;
      mov (word_at (fp_imm frame_crate_ptr)) (Il.Cell (crate_ptr_cell));
      mov (word_at (fp_imm frame_fns_disp)) frame_fns

  and trans_glue_frame_entry (callsz:size) (spill:fixup) : unit =
    let framesz = SIZE_fixup_mem_sz spill in
      push_new_emitter_with_vregs ();
      iflog (fun _ -> annotate "prologue");
      abi.Abi.abi_emit_fn_prologue (emitter())
        framesz callsz nabi_rust (upcall_fixup "upcall_grow_task");
      write_frame_info_ptrs None;
      iflog (fun _ -> annotate "finished prologue");

  and emitted_quads e =
    Array.sub e.Il.emit_quads 0 e.Il.emit_pc

  and capture_emitted_glue (fix:fixup) (spill:fixup) (g:glue) : unit =
    let e = emitter() in
      iflog (fun _ -> annotate_quads (glue_str cx g));
      let code = { code_fixup = fix;
                   code_quads = emitted_quads e;
                   code_vregs_and_spill = Some (Il.num_vregs e, spill);
                   code_spill_disp = 0L }
      in
        htab_put cx.ctxt_glue_code g code

  and trans_glue_frame_exit (fix:fixup) (spill:fixup) (g:glue) : unit =
    iflog (fun _ -> annotate "epilogue");
    abi.Abi.abi_emit_fn_epilogue (emitter());
    capture_emitted_glue fix spill g;
    pop_emitter ()

  and emit_exit_task_glue (fix:fixup) (g:glue) : unit =
    let name = glue_str cx g in
    let spill = new_fixup (name ^ " spill") in
      push_new_emitter_with_vregs ();
      (* 
       * We return-to-here in a synthetic frame we did not build; our job is
       * merely to call upcall_exit.
       *)
      iflog (fun _ -> annotate "assume 'exited' state");
      trans_void_upcall "upcall_exit" [| |];
      capture_emitted_glue fix spill g;
      pop_emitter ()

  and get_exit_task_glue _ : fixup =
    let g = GLUE_exit_task in
      match htab_search cx.ctxt_glue_code g with
          Some code -> code.code_fixup
        | None ->
            let fix = new_fixup (glue_str cx g) in
              emit_exit_task_glue fix g;
              fix

  (*
   * Closure representation has 3 GEP-parts:
   * 
   *  ......
   *  . gc . gc control word, if mutable
   *  +----+
   *  | rc | refcount
   *  +----+
   * 
   *  +----+
   *  | tf | ----> pair of fn+binding that closure 
   *  +----+   /   targets
   *  | tb | --
   *  +----+
   * 
   *  +----+
   *  | b1 | bound arg1
   *  +----+
   *  .    .
   *  .    .
   *  .    .
   *  +----+
   *  | bN | bound argN
   *  +----+
   *)

  and closure_referent_type
      (bs:Ast.slot array)
      (* FIXME (bug 546448): mutability flag *)
      : Il.referent_ty =
    let rc = Il.ScalarTy word_ty in
    let targ = referent_type abi (mk_simple_ty_fn [||]) in
    let bindings = Array.map (slot_referent_type abi) bs in
      Il.StructTy [| rc; targ; Il.StructTy bindings |]

  (* FIXME (bug 544925): this should eventually use tail calling logic *)

  and emit_fn_binding_glue
      (arg_slots:Ast.slot array)
      (arg_bound_flags:bool array)
      (fix:fixup)
      (g:glue)
      : unit =
    let extract_slots want_bound =
      arr_filter_some
        (arr_map2
           (fun slot bound ->
              if bound = want_bound then Some slot else None)
           arg_slots
           arg_bound_flags)
    in
    let bound_slots = extract_slots true in
    let unbound_slots = extract_slots false in
    let (self_ty:Ast.ty) = mk_simple_ty_fn unbound_slots in
    let (callee_ty:Ast.ty) = mk_simple_ty_fn arg_slots in

    let self_closure_rty = closure_referent_type bound_slots in
    let self_args_rty =
      call_args_referent_type cx 0 self_ty (Some self_closure_rty)
    in
    let callee_args_rty =
      call_args_referent_type cx 0 callee_ty (Some Il.OpaqueTy)
    in

    let callsz = Il.referent_ty_size word_bits callee_args_rty in
    let spill = new_fixup "bind glue spill" in
      trans_glue_frame_entry callsz spill;

      let all_self_args_cell = caller_args_cell self_args_rty in
      let self_indirect_args_cell =
        get_element_ptr all_self_args_cell Abi.calltup_elt_indirect_args
      in
      let closure_cell =
        deref (get_element_ptr self_indirect_args_cell Abi.indirect_args_elt_closure)
      in
      let closure_target_cell = get_element_ptr closure_cell Abi.binding_field_binding in
      let closure_target_fn_cell = get_element_ptr closure_target_cell Abi.binding_field_item in

        merge_bound_args
          self_args_rty callee_args_rty
          arg_slots arg_bound_flags;
        iflog (fun _ -> annotate "call through to closure target fn");

        (* 
         * Closures, unlike first-class [disp,*binding] pairs, contain
         * a fully-resolved target pointer, not a displacement. So we
         * don't want to use callee_fn_ptr or the like to access the
         * contents. We just call through the cell directly.
         *)

        call_code (code_of_cell closure_target_fn_cell);
        trans_glue_frame_exit fix spill g


  (* FIXME (546471): abstract out common glue-emitting logic *)

  and get_fn_binding_glue
      (bind_id:node_id)
      (arg_slots:Ast.slot array)
      (arg_bound_flags:bool array)
      : fixup =
    let g = GLUE_fn_binding bind_id in
      match htab_search cx.ctxt_glue_code g with
          Some code -> code.code_fixup
        | None ->
            let fix = new_fixup (glue_str cx g) in
              emit_fn_binding_glue arg_slots arg_bound_flags fix g;
              fix


  (* 
   * Mem-glue functions are either 'mark', 'drop' or 'free', they take
   * one pointer arg and return nothing.
   *)

  and trans_mem_glue_frame_entry (n_outgoing_args:int) (spill:fixup) : unit =
    let isz = cx.ctxt_abi.Abi.abi_implicit_args_sz in
    let callsz = SIZE_fixed (Int64.add isz (word_n n_outgoing_args)) in
      trans_glue_frame_entry callsz spill

  and get_mem_glue (g:glue) (inner:Il.mem -> unit) : fixup =
    match htab_search cx.ctxt_glue_code g with
        Some code -> code.code_fixup
      | None ->
          begin
            let name = glue_str cx g in
            let fix = new_fixup name in
              (* 
               * Put a temporary code entry in the table to handle
               * recursive emit calls during the generation of the glue
               * function.
               *)
            let tmp_code = { code_fixup = fix;
                             code_quads = [| |];
                             code_vregs_and_spill = None;
                             code_spill_disp = 0L } in
            let spill = new_fixup (name ^ " spill") in
              htab_put cx.ctxt_glue_code g tmp_code;
              trans_mem_glue_frame_entry 1 spill;
              let (arg:Il.mem) = fp_imm arg0_disp in
                inner arg;
                Hashtbl.remove cx.ctxt_glue_code g;
                trans_glue_frame_exit fix spill g;
                fix
          end

  and get_typed_mem_glue
      (g:glue)
      (ty:Ast.ty)
      (inner:Il.cell -> unit)
      : fixup =
    get_mem_glue g (fun mem -> inner (ptr_at mem ty))

  and trace_str b s =
    if b
    then
      begin
        let static = trans_static_string s in
          trans_void_upcall "upcall_trace_str" [| static |]
      end

  and trace_word b w =
    if b
    then
      trans_void_upcall "upcall_trace_word" [| Il.Cell w |]

  and get_drop_glue
      (ty:Ast.ty)
      (curr_iso:Ast.ty_iso option)
      : fixup =
    let g = GLUE_drop ty in
    let inner (arg:Il.cell) =
      trace_str cx.ctxt_sess.Session.sess_trace_drop
        "in drop-glue, dropping";
      trace_word cx.ctxt_sess.Session.sess_trace_drop arg;
      drop_ty ty (deref arg) curr_iso;
      trace_str cx.ctxt_sess.Session.sess_trace_drop
        "drop-glue complete";
    in
      get_typed_mem_glue g ty inner

  and get_free_glue
      (ty:Ast.ty)
      (mctrl:mem_ctrl)
      (curr_iso:Ast.ty_iso option)
      : fixup =
    let g = GLUE_free ty in
    let inner (arg:Il.cell) =
      (* 
       * Free-glue assumes we're looking at a pointer to an 
       * exterior allocation with normal exterior layout. It's
       * just a way to move drop+free out of leaf code. 
       *)
      let (body_mem, _) = need_mem_cell (deref_imm arg exterior_rc_body_off) in
      let vr = next_vreg_cell Il.voidptr_t in
        lea vr body_mem;
        trace_str cx.ctxt_sess.Session.sess_trace_drop
          "in free-glue, calling drop-glue";
        trace_word cx.ctxt_sess.Session.sess_trace_drop vr;
        trans_call_mem_glue (get_drop_glue ty curr_iso) vr;
        trace_str cx.ctxt_sess.Session.sess_trace_drop
          "back in free-glue, calling free";
        if mctrl = MEM_gc
        then
          begin
            emit (Il.binary Il.SUB vr (Il.Cell vr)
                    (imm
                       (Int64.add exterior_rc_body_off
                          (word_n Abi.exterior_gc_malloc_return_adjustment))));
            trans_free vr
          end
        else
          trans_free arg;
        trace_str cx.ctxt_sess.Session.sess_trace_drop
          "free-glue complete";
    in
      get_typed_mem_glue g ty inner


  and get_mark_glue
      (ty:Ast.ty)
      (curr_iso:Ast.ty_iso option)
      : fixup =
    let g = GLUE_mark ty in
    let inner (arg:Il.cell) = mark_ty ty (deref arg) curr_iso in
    let fix = get_typed_mem_glue g ty inner in
      fix

  and get_clone_glue
      (ty:Ast.ty)
      (curr_iso:Ast.ty_iso option)
      : fixup =
    let g = GLUE_clone ty in
    let inner (arg:Il.cell) =
      let dst = deref (ptr_at (fp_imm out_mem_disp) ty) in
      let src = deref arg in
        (* FIXME: Gross hack here: we know clone_task is one-past arg
         * in clone glue args.
         *)
      let clone_task = word_at (fp_imm (Int64.add arg0_disp (word_n 1))) in
        clone_ty clone_task ty dst src curr_iso
    in
    let fix = get_typed_mem_glue g ty inner in
      fix

  and get_copy_glue
      (ty:Ast.ty)
      (curr_iso:Ast.ty_iso option)
      : fixup =
    let g = GLUE_copy ty in
    let inner (arg:Il.cell) =
      let dst = deref (ptr_at (fp_imm out_mem_disp) ty) in
      let src = deref arg in
        copy_ty ty dst src curr_iso
    in
    let fix = get_typed_mem_glue g ty inner in
      fix

  (*
   * Glue functions use the same calling convention as ordinary functions.
   *
   * Each glue function expects its own particular arguments, which are
   * usually aliases-- ie, caller doesn't transfer ownership to the glue.
   *)

  and trans_call_clone_glue
      (dst:Il.cell)
      (fix:fixup)
      (arg:Il.cell)
      (clone_task:Il.cell)
      : unit =
    let code = fixup_to_code fix in
    let arg_tup = arg_tup_cell [| word_slot; word_slot |] in
      (* Arg0 is target of clone, to which we write. *)
      (* Arg1 is task-pointer, as usual. *)
      (* Arg2 is the address of the slot we're cloning. *)
      (* Arg3 is the task that will own the data. *)
      aliasing true dst
        begin
          fun dst ->
            mov (get_element_ptr arg_tup 0) (Il.Cell dst);
            mov (get_element_ptr arg_tup 1) (Il.Cell abi.Abi.abi_tp_cell);
            mov (get_element_ptr arg_tup 2) (Il.Cell arg);
            mov (get_element_ptr arg_tup 3) (Il.Cell clone_task);
            call_code code
        end

  and trans_call_copy_glue
      (glue:Il.cell)
      (dst:Il.cell)
      (src:Il.cell)
      : unit =
    let code = code_of_cell glue  in
    let arg_tup = arg_tup_cell [| word_slot |] in
      (* Arg0 is target of copy, to which we write. *)
      (* Arg1 is task-pointer, as usual. *)
      (* Arg2 is the address of the slot we're cloning. *)
      aliasing true dst
        begin
          fun dst ->
            mov (get_element_ptr arg_tup 0) (Il.Cell dst);
            mov (get_element_ptr arg_tup 1) (Il.Cell abi.Abi.abi_tp_cell);
            mov (get_element_ptr arg_tup 2) (Il.Cell src);
            call_code code
        end

  and trans_call_mem_glue (fix:fixup) (arg:Il.cell) : unit =
    let code = fixup_to_code fix in
    let arg_tup = arg_tup_cell [| word_slot |] in
      (* Arg0 we ignore, not present. *)
      (* Arg1 is task-pointer, as usual. *)
      (* Arg2 is the sole pointer we pass in. *)
      mov (get_element_ptr arg_tup 1) (Il.Cell abi.Abi.abi_tp_cell);
      mov (get_element_ptr arg_tup 2) (Il.Cell arg);
      call_code code

  (* trans_compare returns a quad number of the cjmp, which the caller
     patches to the cjmp destination.  *)
  and trans_compare
      (cjmp:Il.jmpop)
      (lhs:Il.operand)
      (rhs:Il.operand)
      : quad_idx list =
    (* FIXME: this is an x86-ism; abstract via ABI. *)
    emit (Il.cmp (Il.Cell (Il.Reg (force_to_reg lhs))) rhs);
    let jmp = mark() in
      emit (Il.jmp cjmp Il.CodeNone);
      [jmp]

  and trans_cond (invert:bool) (expr:Ast.expr) : quad_idx list =

    let anno _ =
      iflog
        begin
          fun _ ->
            annotate ((Ast.fmt_to_str Ast.fmt_expr expr) ^
                        ": cond, finale")
        end
    in

    match expr with
        Ast.EXPR_binary (binop, a, b) ->
          let lhs = trans_atom a in
          let rhs = trans_atom b in
          let cjmp = binop_to_jmpop binop in
          let cjmp' =
            if invert then
              match cjmp with
                  Il.JE -> Il.JNE
                | Il.JNE -> Il.JE
                | Il.JL -> Il.JGE
                | Il.JLE -> Il.JG
                | Il.JGE -> Il.JL
                | Il.JG -> Il.JLE
                | _ -> bug () "Unhandled inverse binop in trans_cond"
            else
              cjmp
          in
            anno ();
            trans_compare cjmp' lhs rhs

      | _ ->
          let bool_operand = trans_expr expr in
            anno ();
            trans_compare Il.JNE bool_operand
              (if invert then imm_true else imm_false)

  and trans_binary
      (binop:Ast.binop)
      (lhs:Il.operand)
      (rhs:Il.operand) : Il.operand =
    let arith op =
      let bits = Il.operand_bits word_bits lhs in
      let dst = Il.Reg (Il.next_vreg (emitter()), Il.ValTy bits) in
        emit (Il.binary op dst lhs rhs);
        Il.Cell dst
    in
    match binop with
        Ast.BINOP_or -> arith Il.OR
      | Ast.BINOP_and -> arith Il.AND

      | Ast.BINOP_lsl -> arith Il.LSL
      | Ast.BINOP_lsr -> arith Il.LSR
      | Ast.BINOP_asr -> arith Il.ASR

      | Ast.BINOP_add -> arith Il.ADD
      | Ast.BINOP_sub -> arith Il.SUB

      (* FIXME (bug 541544): switch on type of operands, IMUL/IDIV/IMOD etc. *)
      | Ast.BINOP_mul -> arith Il.UMUL
      | Ast.BINOP_div -> arith Il.UDIV
      | Ast.BINOP_mod -> arith Il.UMOD

      | _ -> let dst = Il.Reg (Il.next_vreg (emitter()), Il.ValTy Il.Bits8) in
          mov dst imm_true;
          let jmps = trans_compare (binop_to_jmpop binop) lhs rhs in
            mov dst imm_false;
            List.iter patch jmps;
            Il.Cell dst


  and trans_expr (expr:Ast.expr) : Il.operand =

    let anno _ =
      iflog
        begin
          fun _ ->
            annotate ((Ast.fmt_to_str Ast.fmt_expr expr) ^
                        ": plain exit, finale")
        end
    in

    match expr with

        Ast.EXPR_binary (binop, a, b) ->
          trans_binary binop (trans_atom a) (trans_atom b)

      | Ast.EXPR_unary (unop, a) ->
          let src = trans_atom a in
          let bits = Il.operand_bits word_bits src in
          let dst = Il.Reg (Il.next_vreg (emitter()), Il.ValTy bits) in
          let op = match unop with
              Ast.UNOP_not -> Il.NOT
            | Ast.UNOP_neg -> Il.NEG
            | Ast.UNOP_cast t ->
                let at = atom_type cx a in
                if (type_is_2s_complement at) &&
                  (type_is_2s_complement t)
                then
                  if type_is_unsigned_2s_complement t
                  then Il.UMOV
                  else Il.IMOV
                else
                  err None "unsupported cast operator"
          in
            anno ();
            emit (Il.unary op dst src);
            Il.Cell dst

      | Ast.EXPR_atom a ->
          trans_atom a

  and trans_block (block:Ast.block) : unit =
    trace_str cx.ctxt_sess.Session.sess_trace_block
      "entering block";
    emit (Il.Enter (Hashtbl.find cx.ctxt_block_fixups block.id));
    Array.iter trans_stmt block.node;
    trace_str cx.ctxt_sess.Session.sess_trace_block
      "exiting block";
    iter_block_slots block.id
      begin
        fun slotkey slot_id slot ->
          if (not (slot_is_obj_state cx slot_id))
          then
            begin
              (* FIXME (bug 541543): this is not going to free things in
               * the proper order; we need to analyze the decl order in an
               * earlier phase and thread it through to here.  *)
              iflog
                begin
                  fun _ ->
                    annotate
                      ("drop slot: " ^
                         (Ast.fmt_to_str Ast.fmt_slot_key slotkey))
                end;
              trace_str cx.ctxt_sess.Session.sess_trace_drop
                ("dropping slot " ^ (Ast.fmt_to_str Ast.fmt_slot_key slotkey));
              let cell = cell_of_block_slot slot_id in
                drop_slot cell slot None
            end;
      end;
    emit Il.Leave;
    trace_str cx.ctxt_sess.Session.sess_trace_block
      "exited block";

  and upcall_fixup (name:string) : fixup =
    Semant.require_native cx REQUIRED_LIB_rustrt name;

  and trans_upcall
      (name:string)
      (ret:Il.cell)
      (args:Il.operand array)
      : unit =
    abi.Abi.abi_emit_native_call (emitter())
      ret nabi_rust (upcall_fixup name) args;

  and trans_void_upcall
      (name:string)
      (args:Il.operand array)
      : unit =
    abi.Abi.abi_emit_native_void_call (emitter())
      nabi_rust (upcall_fixup name) args;

  and trans_log_int (a:Ast.atom) : unit =
    trans_void_upcall "upcall_log_int" [| (trans_atom a) |]

  and trans_log_str (a:Ast.atom) : unit =
    trans_void_upcall "upcall_log_str" [| (trans_atom a) |]

  and trans_spawn
      ((*initializing*)_:bool)
      (dst:Ast.lval)
      (domain:Ast.domain)
      (fn_lval:Ast.lval)
      (args:Ast.atom array)
      : unit =
    let (task_cell, _) = trans_lval_init dst in
    let (fptr_operand, fn_ty) = trans_callee fn_lval in
    (*let fn_ty_params = [| |] in*)
    let _ =
      (* FIXME: handle indirect-spawns (clone closure?). *)
      if not (lval_is_direct_fn cx fn_lval)
      then bug () "unhandled indirect-spawn"
    in
    let args_rty = call_args_referent_type cx 0 fn_ty None in
    let fptr_operand = reify_ptr fptr_operand in
    let exit_task_glue_fixup = get_exit_task_glue () in
    let callsz =
      calculate_sz_in_current_frame (Il.referent_ty_size word_bits args_rty)
    in
    let exit_task_glue_fptr = code_fixup_to_ptr_operand exit_task_glue_fixup in
    let exit_task_glue_fptr = reify_ptr exit_task_glue_fptr in

      iflog (fun _ -> annotate "spawn task: copy args");

      let new_task = next_vreg_cell Il.voidptr_t in
      let call = { call_ctrl = CALL_indirect;
                   call_callee_ptr = fptr_operand;
                   call_callee_ty = fn_ty;
                   call_callee_ty_params = [| |];
                   call_output = task_cell;
                   call_args = args;
                   call_iterator_args = [| |];
                   call_indirect_args = [| |] }
      in
        match domain with
            Ast.DOMAIN_thread ->
              begin
                trans_upcall "upcall_new_thread" new_task [| |];
                copy_fn_args false (CLONE_all new_task) call;
                trans_upcall "upcall_start_thread" task_cell
                  [|
                    Il.Cell new_task;
                    exit_task_glue_fptr;
                    fptr_operand;
                    callsz
                  |];
            end
         | _ ->
             begin
                 trans_upcall "upcall_new_task" new_task [| |];
                 copy_fn_args false (CLONE_chan new_task) call;
                 trans_upcall "upcall_start_task" task_cell
                   [|
                     Il.Cell new_task;
                     exit_task_glue_fptr;
                     fptr_operand;
                     callsz
                   |];
             end;
      ()

  and trans_cond_fail (str:string) (fwd_jmps:quad_idx list) : unit =
    let (filename, line, _) =
      match !curr_stmt with
          None -> ("<none>", 0, 0)
        | Some stmt_id ->
            match (Session.get_span cx.ctxt_sess stmt_id) with
                None -> ("<none>", 0, 0)
              | Some sp -> sp.lo
    in
      iflog (fun _ -> annotate ("condition-fail: " ^ str));
      trans_void_upcall "upcall_fail"
        [|
          trans_static_string str;
          trans_static_string filename;
          imm (Int64.of_int line)
        |];
      List.iter patch fwd_jmps

  and trans_check_expr (e:Ast.expr) : unit =
    let fwd_jmps = trans_cond false e in
      trans_cond_fail (Ast.fmt_to_str Ast.fmt_expr e) fwd_jmps

  and trans_malloc (dst:Il.cell) (nbytes:int64) : unit =
    trans_upcall "upcall_malloc" dst [| imm nbytes |]

  and trans_free (src:Il.cell) : unit =
    trans_void_upcall "upcall_free" [| Il.Cell src |]

  and trans_yield () : unit =
    trans_void_upcall "upcall_yield" [| |];

  and trans_fail () : unit =
    let (filename, line, _) =
      match !curr_stmt with
          None -> ("<none>", 0, 0)
        | Some stmt_id ->
            match (Session.get_span cx.ctxt_sess stmt_id) with
                None -> ("<none>", 0, 0)
              | Some sp -> sp.lo
    in
      trans_void_upcall "upcall_fail"
        [|
          trans_static_string "explicit failure";
          trans_static_string filename;
          imm (Int64.of_int line)
        |];

  and trans_join (task:Ast.lval) : unit =
    trans_void_upcall "upcall_join" [| trans_atom (Ast.ATOM_lval task) |]

  and trans_send (chan:Ast.lval) (src:Ast.lval) : unit =
    let (srccell, _) = trans_lval src in
      aliasing false srccell
        begin
          fun src_alias ->
            trans_void_upcall "upcall_send" [| trans_atom (Ast.ATOM_lval chan);
                                               Il.Cell src_alias |];
        end

  and trans_recv (initializing:bool) (dst:Ast.lval) (chan:Ast.lval) : unit =
    let (dstcell, _) = trans_lval_maybe_init initializing dst in
      aliasing true dstcell
        begin
          fun dst_alias ->
            trans_void_upcall "upcall_recv"
              [| Il.Cell dst_alias;
                 trans_atom (Ast.ATOM_lval chan) |];
        end

  and trans_init_port (dst:Ast.lval) : unit =
    let (dstcell, dst_slot) = trans_lval_init dst in
    let unit_ty = match slot_ty dst_slot with
        Ast.TY_port t -> t
      | _ -> bug () "init dst of port-init has non-port type"
    in
    let unit_sz = ty_sz abi unit_ty in
      trans_upcall "upcall_new_port" dstcell [| imm unit_sz |]

  and trans_del_port (port:Il.cell) : unit =
    trans_void_upcall "upcall_del_port" [| Il.Cell port |]

  and trans_init_chan (dst:Ast.lval) (port:Ast.lval) : unit =
    let (dstcell, _) = trans_lval_init dst
    in
      trans_upcall "upcall_new_chan" dstcell
        [| trans_atom (Ast.ATOM_lval port) |]

  and trans_del_chan (chan:Il.cell) : unit =
    trans_void_upcall "upcall_del_chan" [| Il.Cell chan |]

  and trans_kill_task (task:Il.cell) : unit =
    trans_void_upcall "upcall_kill" [| Il.Cell task |]

  (*
   * A vec is implicitly exterior: every slot vec[T] is 1 word and
   * points to a refcounted structure. That structure has 3 words with
   * defined meaning at the beginning; data follows the header.
   *
   *   word 0: refcount or gc control word
   *   word 1: allocated size of data
   *   word 2: initialised size of data
   *   word 3...N: data
   * 
   * This 3-word prefix is shared with strings, we factor the common
   * part out for reuse in string code.
   *)

  and trans_init_vec (dst:Ast.lval) (atoms:Ast.atom array) : unit =
    let (dstcell, dst_slot) = trans_lval_init dst in
    let unit_slot = match slot_ty dst_slot with
        Ast.TY_vec s -> s
      | _ -> bug () "init dst of vec-init has non-vec type"
    in
    let unit_sz = slot_sz abi unit_slot in
    let n_inits = Array.length atoms in
    let init_sz = Int64.mul unit_sz (Int64.of_int n_inits) in
    let padded_sz = Int64.add init_sz (word_n 3) in
    let alloc_sz = next_power_of_two padded_sz in
      trans_malloc dstcell alloc_sz;
      let vec = deref dstcell in
        mov (get_element_ptr vec 0) one;
        mov (get_element_ptr vec 1) (imm alloc_sz);
        mov (get_element_ptr vec 2) (imm init_sz);
        let body_mem = fst (need_mem_cell (get_element_ptr vec 3)) in
        let unit_rty = slot_referent_type abi unit_slot in
        let body_rty = Il.StructTy (Array.map (fun _ -> unit_rty) atoms) in
        let body = Il.Mem (body_mem, body_rty) in
          Array.iteri
            begin
              fun i atom ->
                let cell = get_element_ptr body i in
                  trans_init_slot_from_atom CLONE_none cell unit_slot atom
            end
            atoms

  and next_power_of_two (x:int64) : int64 =
    let xr = ref (Int64.sub x 1L) in
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 1);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 2);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 4);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 8);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 16);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 32);
      Int64.add 1L (!xr)

  and exterior_ctrl_cell (cell:Il.cell) (off:int) : Il.cell =
    let (rc_mem, _) = need_mem_cell (deref_imm cell (word_n off)) in
    word_at rc_mem

  and exterior_rc_cell (cell:Il.cell) : Il.cell =
    exterior_ctrl_cell cell Abi.exterior_rc_slot_field_refcnt

  and exterior_gc_ctrl_cell (cell:Il.cell) : Il.cell =
    exterior_ctrl_cell cell Abi.exterior_gc_slot_field_ctrl

  and exterior_gc_next_cell (cell:Il.cell) : Il.cell =
    exterior_ctrl_cell cell Abi.exterior_gc_slot_field_next

  and exterior_gc_allocation_size (slot:Ast.slot) : int64 =
    (Int64.add
       (ty_sz  abi (slot_ty slot))
       (word_n Abi.exterior_gc_header_size))

  and exterior_rc_allocation_size (slot:Ast.slot) : int64 =
      (Int64.add
         (ty_sz abi (slot_ty slot))
         (word_n Abi.exterior_rc_header_size))


  and ty_is_structured (t:Ast.ty) : bool =
    let fold = ty_fold_bool_or false in
    let fold = { fold with
                   ty_fold_tup = (fun _ -> true);
                   ty_fold_vec = (fun _ -> true);
                   ty_fold_rec = (fun _ -> true);
                   ty_fold_tag = (fun _ -> true);
                   ty_fold_iso = (fun _ -> true);
                   ty_fold_idx = (fun _ -> true);
                   ty_fold_fn = (fun _ -> true);
                   ty_fold_pred = (fun _ -> true);
                   ty_fold_obj = (fun _ -> true) }
    in
      fold_ty fold t


  and slot_mem_ctrl (slot:Ast.slot) : mem_ctrl =
    let ty = slot_ty slot in
      if type_is_mutable ty
      then
        match slot.Ast.slot_mode with
            Ast.MODE_exterior _ -> MEM_gc
          | _ -> MEM_interior
      else
        match ty with
            Ast.TY_port _ -> MEM_rc_opaque Abi.port_field_refcnt
          | Ast.TY_chan _ -> MEM_rc_opaque Abi.chan_field_refcnt
          | Ast.TY_task -> MEM_rc_opaque Abi.task_field_refcnt
              (* Vecs and strs are pseudo-exterior. *)
          | Ast.TY_vec _ -> MEM_rc_struct
          | Ast.TY_str -> MEM_rc_opaque Abi.exterior_rc_slot_field_refcnt
          | _ ->
              match slot.Ast.slot_mode with
                  Ast.MODE_exterior _ when ty_is_structured (slot_ty slot) ->
                    MEM_rc_struct
                | Ast.MODE_exterior _ ->
                    MEM_rc_opaque Abi.exterior_rc_slot_field_refcnt
                | _ ->
                    MEM_interior

  and iter_rec_slots
      (dst_cell:Il.cell)
      (src_cell:Il.cell)
      (entries:Ast.ty_rec)
      (f:Il.cell -> Il.cell -> Ast.slot -> (Ast.ty_iso option) -> unit)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_tup_slots dst_cell src_cell (Array.map snd entries) f curr_iso

  and iter_tup_slots
      (dst_cell:Il.cell)
      (src_cell:Il.cell)
      (slots:Ast.ty_tup)
      (f:Il.cell -> Il.cell -> Ast.slot -> (Ast.ty_iso option) -> unit)
      (curr_iso:Ast.ty_iso option)
      : unit =
    Array.iteri
      begin
        fun i slot ->
          f (get_element_ptr dst_cell i)
            (get_element_ptr src_cell i)
            slot curr_iso
      end
      slots

  and iter_tag_slots
        (dst_cell:Il.cell)
        (src_cell:Il.cell)
        (ttag:Ast.ty_tag)
        (f:Il.cell -> Il.cell -> Ast.slot -> (Ast.ty_iso option) -> unit)
        (curr_iso:Ast.ty_iso option)
        : unit =
      let tag_keys = sorted_htab_keys ttag in
      let src_tag = get_element_ptr src_cell 0 in
      let dst_tag = get_element_ptr dst_cell 0 in
      let src_union = get_element_ptr src_cell 1 in
      let dst_union = get_element_ptr dst_cell 1 in
      let tmp = next_vreg_cell word_ty in
        f dst_tag src_tag word_slot curr_iso;
        mov tmp (Il.Cell src_tag);
        Array.iteri
          begin
            fun i key ->
              (iflog (fun _ ->
                        annotate (Printf.sprintf "tag case #%i == %a" i
                                    Ast.sprintf_name key)));
              let jmps =
                trans_compare Il.JNE (Il.Cell tmp) (imm (Int64.of_int i))
              in
              let ttup = Hashtbl.find ttag key in
                iter_tup_slots
                  (get_variant_ptr dst_union i)
                  (get_variant_ptr src_union i)
                  ttup f curr_iso;
                List.iter patch jmps
          end
          tag_keys

  and get_iso_tag tiso =
    tiso.Ast.iso_group.(tiso.Ast.iso_index)

  and iter_ty_slots_full
        (ty:Ast.ty)
        (dst_cell:Il.cell)
        (src_cell:Il.cell)
        (f:Il.cell -> Il.cell -> Ast.slot -> (Ast.ty_iso option) -> unit)
        (curr_iso:Ast.ty_iso option)
        : unit =
        (* 
         * FIXME: this will require some reworking if we support
         * rec, tag or tup slots that fit in a vreg. It requires 
         * addrs presently.
         *)
        match ty with
            Ast.TY_rec entries ->
              iter_rec_slots dst_cell src_cell entries f curr_iso

          | Ast.TY_tup slots ->
              iter_tup_slots dst_cell src_cell slots f curr_iso

          | Ast.TY_tag tag ->
              iter_tag_slots dst_cell src_cell tag f curr_iso

          | Ast.TY_iso tiso ->
              let ttag = get_iso_tag tiso in
                iter_tag_slots dst_cell src_cell ttag f (Some tiso)

          | Ast.TY_fn _
          | Ast.TY_pred _
          | Ast.TY_obj _ ->

              (* Fake-int to provoke copying of the static part. *)
              let src_fn_field_cell = get_element_ptr src_cell 0 in
              let dst_fn_field_cell = get_element_ptr dst_cell 0 in
                f dst_fn_field_cell
                  src_fn_field_cell
                  (interior_slot Ast.TY_int) curr_iso;

                let src_binding_field_cell = get_element_ptr src_cell 1 in
                let dst_binding_field_cell = get_element_ptr dst_cell 1 in
                  emit (Il.cmp (Il.Cell src_binding_field_cell) zero);
                  let null_jmp = mark() in
                    emit (Il.jmp Il.JE Il.CodeNone);
                    (* TY_fn and TY_mod are stored as pairs
                     * [item_ptr, closure_ptr].
                     *)
                    (* Call thunk if we have a src binding. *)
                    (* FIXME (bug 543738): this is completely wrong,
                     * need a second thunk that generates code to make
                     * use of a runtime type descriptor extracted from
                     * a binding tuple. For now this only works by
                     * accident. 
                     *)
                    (f dst_binding_field_cell
                       src_binding_field_cell
                       (exterior_slot Ast.TY_int) curr_iso);
                    patch null_jmp

          | _ -> ()

  (* 
   * This just calls iter_ty_slots_full with your cell as both src and
   * dst, with an adaptor function that discards the dst slots of the
   * parallel traversal and and calls your provided function on the
   * passed-in src slots.
   *)
  and iter_ty_slots
      (ty:Ast.ty)
      (cell:Il.cell)
      (f:Il.cell -> Ast.slot -> (Ast.ty_iso option) -> unit)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_ty_slots_full ty cell cell
      (fun _ src_cell slot curr_iso -> f src_cell slot curr_iso)
      curr_iso

  and drop_ty
      (ty:Ast.ty)
      (cell:Il.cell)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_ty_slots ty cell drop_slot curr_iso

  and mark_ty
      (ty:Ast.ty)
      (cell:Il.cell)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iter_ty_slots ty cell mark_slot curr_iso

  and clone_ty
      (clone_task:Il.cell)
      (ty:Ast.ty)
      (dst:Il.cell)
      (src:Il.cell)
      (curr_iso:Ast.ty_iso option)
      : unit =
    match ty with
        Ast.TY_chan _ ->
          trans_upcall "upcall_clone_chan" dst
            [| (Il.Cell clone_task); (Il.Cell src) |]
      | Ast.TY_task
      | Ast.TY_port _
      | _ when type_is_mutable ty
          -> bug () "cloning mutable type"
      | _ when i64_le (ty_sz abi ty) word_sz
          -> mov dst (Il.Cell src)
      | _ -> iter_ty_slots_full ty dst src (clone_slot clone_task) curr_iso

  and copy_ty
      (ty:Ast.ty)
      (dst:Il.cell)
      (src:Il.cell)
      (curr_iso:Ast.ty_iso option)
      : unit =
    iflog (fun _ ->
             annotate ("copy_ty: referent data of type " ^
                         (Ast.fmt_to_str Ast.fmt_ty ty)));
    match ty with
        Ast.TY_nil
      | Ast.TY_bool
      | Ast.TY_mach _
      | Ast.TY_int
      | Ast.TY_char ->
          begin
            iflog (fun _ -> annotate
                     (Printf.sprintf "copy_ty: simple mov (%Ld byte scalar)"
                        (ty_sz abi ty)));
            mov dst (Il.Cell src)
          end

      | Ast.TY_param (i, _) ->
          begin
            iflog (fun _ -> annotate
                     (Printf.sprintf "copy_ty: parametric copy %#d" i));
            let ty_desc = get_current_fn_ty_desc i in
            let copy_glue =
              get_element_ptr ty_desc Abi.tydesc_field_copy_glue
            in
            let copy_glue_ptr =
              crate_rel_to_ptr (Il.Cell copy_glue) Il.CodeTy
            in
              aliasing false src
                (fun src ->
                   trans_call_copy_glue copy_glue_ptr dst src)
          end

      | _ ->
          iter_ty_slots_full ty dst src
            (fun dst src slot curr_iso ->
               trans_copy_slot true dst slot src slot curr_iso)
            curr_iso

  and free_ty
      (ty:Ast.ty)
      (cell:Il.cell)
      : unit =
    match ty with
        Ast.TY_port _ -> trans_del_port cell
      | Ast.TY_chan _ -> trans_del_chan cell
      | Ast.TY_task -> trans_kill_task cell
      | _ -> trans_free cell

  and maybe_iso
      (curr_iso:Ast.ty_iso option)
      (t:Ast.ty)
      : Ast.ty =
    match (curr_iso, t) with
        (Some iso, Ast.TY_idx n) ->
          Ast.TY_iso { iso with Ast.iso_index = n }
      | (None, Ast.TY_idx _) ->
          bug () "TY_idx outside TY_iso"
      | _ -> t

  and maybe_enter_iso
      (t:Ast.ty)
      (curr_iso:Ast.ty_iso option)
      : Ast.ty_iso option =
    match t with
        Ast.TY_iso tiso -> Some tiso
      | _ -> curr_iso

  and mark_slot
      (cell:Il.cell)
      (slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =
    let ty = slot_ty slot in
      match slot_mem_ctrl slot with
          MEM_gc ->
            (iflog (fun _ -> annotate ("mark GC slot " ^
                                         (Ast.fmt_to_str Ast.fmt_slot slot))));
            log cx "marking MEM_gc slot: %a" Ast.sprintf_slot slot;
            emit (Il.cmp (Il.Cell cell) zero);
            let null_cell_jump = mark () in
              emit (Il.jmp Il.JE Il.CodeNone);
              let gc_word = exterior_gc_ctrl_cell cell in
              let tmp = next_vreg_cell Il.voidptr_t in
                (* if this has been marked already, jump to exit.*)
                emit (Il.binary Il.AND tmp (Il.Cell gc_word) one);
                let already_marked_jump = mark () in
                  emit (Il.jmp Il.JNZ Il.CodeNone);
                  (* Set mark bit in allocation header. *)
                  emit (Il.binary Il.OR gc_word (Il.Cell gc_word) one);
                  (* Iterate over exterior slots marking outgoing links. *)
                  let (body_mem, _) =
                    need_mem_cell (deref_imm cell exterior_gc_body_off)
                  in
                  let ty = maybe_iso curr_iso ty in
                  let curr_iso = maybe_enter_iso ty curr_iso in
                    lea tmp body_mem;
                    trans_call_mem_glue (get_mark_glue ty curr_iso) tmp;
                    patch null_cell_jump;
                    patch already_marked_jump

        | MEM_interior when ty_is_structured ty ->
            (iflog (fun _ -> annotate ("mark interior slot " ^
                                         (Ast.fmt_to_str Ast.fmt_slot slot))));
            let (mem, _) = need_mem_cell cell in
            let tmp = next_vreg_cell Il.voidptr_t in
            let ty = maybe_iso curr_iso ty in
            let curr_iso = maybe_enter_iso ty curr_iso in
              lea tmp mem;
              trans_call_mem_glue (get_mark_glue ty curr_iso) tmp

        | _ -> ()

  and check_exterior_rty cell =
    match cell with
        Il.Reg (_, Il.AddrTy (Il.StructTy fields))
      | Il.Mem (_, Il.ScalarTy (Il.AddrTy (Il.StructTy fields)))
          when (((Array.length fields) > 0) && (fields.(0) = word_rty)) -> ()
      | _ -> bug ()
          "expected plausibly-exterior cell, got %s"
            (Il.string_of_referent_ty (Il.cell_referent_ty cell))

  and clone_slot
      (clone_task:Il.cell)
      (dst:Il.cell)
      (src:Il.cell)
      (dst_slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =
    let ty = slot_ty dst_slot in
      match dst_slot.Ast.slot_mode with
          Ast.MODE_exterior _ ->
            let ty = maybe_iso curr_iso ty in
            let curr_iso = maybe_enter_iso ty curr_iso in
            let dst = deref_slot true dst dst_slot in
            let glue_fix = get_clone_glue (slot_ty dst_slot) curr_iso in
              trans_call_clone_glue dst glue_fix src clone_task

        | Ast.MODE_read_alias
        | Ast.MODE_write_alias -> bug () "cloning into alias slot"
        | Ast.MODE_interior _ -> clone_ty clone_task ty dst src curr_iso

  and drop_slot
      (cell:Il.cell)
      (slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =
    let null_check _ =
      emit (Il.cmp (Il.Cell cell) zero);
      let j = mark() in
        emit (Il.jmp Il.JE Il.CodeNone);
        j
    in
    let drop_refcount_and_cmp rc =
      (iflog (fun _ -> annotate ("drop refcount and maybe free slot " ^
                                   (Ast.fmt_to_str Ast.fmt_slot slot))));
      emit (Il.binary Il.SUB rc (Il.Cell rc) one);
      emit (Il.cmp (Il.Cell rc) zero);
      let j = mark () in
        emit (Il.jmp Il.JNE Il.CodeNone);
        j
    in
    let ty = slot_ty slot in
    let mctrl = slot_mem_ctrl slot in
      match mctrl with
          MEM_rc_opaque rc_off ->
            (* Refcounted opaque objects we handle without glue functions. *)
            let _ = check_exterior_rty cell in
            let null_jmp = null_check () in
            let (rc_mem, _) = need_mem_cell (deref_imm cell (word_n rc_off)) in
            let rc = word_at rc_mem in
            let j = drop_refcount_and_cmp rc in
              free_ty ty cell;
              (* Null the slot out to prevent double-free if the frame
               * unwinds.
               *)
              mov cell zero;
              patch j;
              patch null_jmp

        | MEM_gc
        | MEM_rc_struct ->
            (* Refcounted "structured exterior" objects we handle via
             * glue functions.
             *)

            (* 
             * 'GC memory' is treated similarly, just happens to have
             * an extra couple cells on the front.
             *)

            (* FIXME (bug 541542): check to see that the exterior has
             * further exterior members; if it doesn't we can elide the
             * call to the glue function.  *)
            let _ = check_exterior_rty cell in
            let null_jmp = null_check () in
            let rc = exterior_rc_cell cell in
            let j = drop_refcount_and_cmp rc in
            let ty = maybe_iso curr_iso ty in
            let curr_iso = maybe_enter_iso ty curr_iso in
              trans_call_mem_glue (get_free_glue ty mctrl curr_iso) cell;
              (* Null the slot out to prevent double-free if the frame
               * unwinds.
               *)
              mov cell zero;
              patch j;
              patch null_jmp

        | MEM_interior when ty_is_structured ty ->
            (iflog (fun _ -> annotate ("drop interior slot " ^
                                         (Ast.fmt_to_str Ast.fmt_slot slot))));
            let (mem, _) = need_mem_cell cell in
            let vr = next_vreg_cell Il.voidptr_t in
            let ty = maybe_iso curr_iso ty in
            let curr_iso = maybe_enter_iso ty curr_iso in
              lea vr mem;
              trans_call_mem_glue (get_drop_glue ty curr_iso) vr

        | MEM_interior ->
            (* Interior allocation of all-interior value: nothing to do. *)
            ()

  and exterior_body_off (slot:Ast.slot) : int64 =
      match slot_mem_ctrl slot with
          MEM_gc -> exterior_gc_body_off
        | MEM_rc_struct -> exterior_rc_body_off
        | MEM_rc_opaque _
        | MEM_interior -> bug () "exterior_body_off of MEM_interior"

  (* Returns the offset of the slot-body in the initialized allocation. *)
  and init_exterior_slot (cell:Il.cell) (slot:Ast.slot) : unit =
      match slot_mem_ctrl slot with
          MEM_gc ->
            iflog (fun _ -> annotate "init GC exterior: malloc");
            let sz = exterior_gc_allocation_size slot in
              (* 
               * Malloc and then immediately shift down to point to
               * the pseudo-rc cell.
               *)
              trans_malloc cell sz;
              emit (Il.binary Il.ADD cell (Il.Cell cell)
                      (imm (word_n Abi.exterior_gc_malloc_return_adjustment)));

              iflog (fun _ -> annotate "init GC exterior: load control word");
              let ctrl = exterior_gc_ctrl_cell cell in
              let fix = get_drop_glue (slot_ty slot) None in
              let tmp = next_vreg_cell Il.voidptr_t in
              let rc = exterior_rc_cell cell in
                mov rc one;
                lea tmp (Il.Abs (Asm.M_POS fix));
                mov ctrl (Il.Cell tmp);
                iflog (fun _ -> annotate "init GC exterior: load next-pointer");
                let next = exterior_gc_next_cell cell in
                  mov next (Il.Cell
                              (tp_imm (word_n Abi.task_field_gc_alloc_chain)));

        | MEM_rc_opaque rc_off ->
            iflog (fun _ -> annotate "init RC exterior: malloc");
            let sz = exterior_rc_allocation_size slot in
              trans_malloc cell sz;
              iflog (fun _ -> annotate "init RC exterior: load refcount");
              let rc = exterior_ctrl_cell cell rc_off in
                mov rc one

        | MEM_rc_struct ->
            iflog (fun _ -> annotate "init RC exterior: malloc");
            let sz = exterior_rc_allocation_size slot in
              trans_malloc cell sz;
              iflog (fun _ -> annotate "init RC exterior: load refcount");
              let rc = exterior_rc_cell cell in
                mov rc one

        | MEM_interior -> bug () "init_exterior_slot of MEM_interior"

  and deref_exterior
      (initializing:bool)
      (cell:Il.cell)
      (slot:Ast.slot)
      : Il.typed_mem =
    let body_ty =
      match pointee_type cell with
          Il.StructTy parts
            when (Array.length parts == 2) &&
              (parts.(0) = Il.ScalarTy word_ty) -> parts.(1)
        | ty -> bug () "Dereferencing exterior cell with bad IL type: %s"
            (Il.string_of_referent_ty ty)
    in
      iflog (fun _ -> annotate ("deref exterior: " ^
                                  (if initializing
                                   then "init"
                                   else "access") ^ ", " ^
                                  (Il.string_of_cell
                                     abi.Abi.abi_str_of_hardreg cell)));
      if initializing
      then init_exterior_slot cell slot;
      let (mem, _) =
        need_mem_cell (deref_imm cell (exterior_body_off slot))
      in
        (mem, body_ty)

  and deref_slot (initializing:bool) (cell:Il.cell) (slot:Ast.slot) : Il.cell =
    match slot.Ast.slot_mode with
        Ast.MODE_interior _ -> cell
      | Ast.MODE_exterior _ -> Il.Mem (deref_exterior initializing cell slot)
      | Ast.MODE_read_alias
      | Ast.MODE_write_alias ->
          if initializing
          then cell
          else deref cell

  and trans_copy_tup
      (initializing:bool)
      (dst:Il.cell)
      (src:Il.cell)
      (slots:Ast.ty_tup)
      : unit =
    Array.iteri
      begin
        fun i slot ->
          let sub_dst_cell = get_element_ptr dst i in
          let sub_src_cell = get_element_ptr src i in
            trans_copy_slot initializing
              sub_dst_cell slot sub_src_cell slot None
      end
      slots

  and trans_copy_slot
      (initializing:bool)
      (dst:Il.cell) (dst_slot:Ast.slot)
      (src:Il.cell) (src_slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =
    let anno (weight:string) : unit =
      iflog
        begin
          fun _ ->
            annotate
              (Printf.sprintf "%sweight copy: %a <- %a"
                 weight
                 Ast.sprintf_slot dst_slot
                 Ast.sprintf_slot src_slot)
        end;
    in
    let lightweight_rc src_rc =
      (* Lightweight copy: twiddle refcounts, move pointer. *)
      anno "refcounted light";
      emit (Il.binary Il.ADD src_rc (Il.Cell src_rc) one);
      if not initializing
      then
        drop_slot dst dst_slot None;
      mov dst (Il.Cell src)
    in

      assert (slot_ty src_slot = slot_ty dst_slot);
      match (slot_mem_ctrl src_slot,
             slot_mem_ctrl dst_slot) with
        | (MEM_rc_opaque src_rc_off, MEM_rc_opaque _) ->
            lightweight_rc (exterior_ctrl_cell src src_rc_off)

        | (MEM_gc, MEM_gc)
        | (MEM_rc_struct, MEM_rc_struct) ->
            lightweight_rc (exterior_rc_cell src)

        | _ ->
            (* Heavyweight copy: duplicate 1 level of the referent. *)
            anno "heavy";
            trans_copy_slot_heavy initializing
              dst dst_slot src src_slot curr_iso

  (* NB: heavyweight copying here does not mean "producing a deep
   * clone of the entire data tree rooted at the src operand". It means
   * "replicating a single level of the tree".
   * 
   * There is no general-recursion entailed in performing a heavy
   * copy. There is only "one level" to each heavy copy call.
   * 
   * In other words, this is a lightweight copy:
   * 
   *    [dstptr]  <-copy-  [srcptr]
   *         \              |
   *          \             |
   *        [some record.rc++]
   *             |
   *           [some other record]
   * 
   * Whereas this is a heavyweight copy:
   * 
   *    [dstptr]  <-copy-  [srcptr]
   *       |                  |
   *       |                  |
   *  [some record]       [some record]
   *             |          |
   *           [some other record]
   * 
   *)

  and trans_copy_slot_heavy
      (initializing:bool)
      (dst:Il.cell) (dst_slot:Ast.slot)
      (src:Il.cell) (src_slot:Ast.slot)
      (curr_iso:Ast.ty_iso option)
      : unit =
    assert (slot_ty src_slot = slot_ty dst_slot);
    iflog (fun _ ->
             annotate ("heavy copy: slot preparation"));

    let ty = slot_ty src_slot in
    let ty = maybe_iso curr_iso ty in
    let curr_iso = maybe_enter_iso ty curr_iso in
    let dst = deref_slot initializing dst dst_slot in
    let src = deref_slot false src src_slot in
      copy_ty ty dst src curr_iso

  and trans_copy
      (initializing:bool)
      (dst:Ast.lval)
      (src:Ast.expr)
      : unit =
    let (dst_cell, dst_slot) = trans_lval_maybe_init initializing dst in
      match src with
          (Ast.EXPR_binary _)
        | (Ast.EXPR_unary _)
        | (Ast.EXPR_atom (Ast.ATOM_literal _)) ->
            (*
             * Translations of these expr types yield vregs,
             * so copy is just MOV into the lval.
             *)
            let src_operand = trans_expr src in
              mov (deref_slot false dst_cell dst_slot) src_operand

        | Ast.EXPR_atom (Ast.ATOM_lval src_lval) ->
            if lval_is_direct_fn cx src_lval then
              trans_copy_direct_fn dst_cell src_lval
            else
              (* Possibly-large structure copying *)
              let (src_cell, src_slot) = trans_lval src_lval in
                trans_copy_slot
                  initializing
                  dst_cell dst_slot
                  src_cell src_slot
                  None

  and trans_copy_direct_fn
      (dst_cell:Il.cell)
      (flv:Ast.lval)
      : unit =
    let item = lval_item cx flv in
    let fix = Hashtbl.find cx.ctxt_fn_fixups item.id in

    let dst_pair_item_cell = get_element_ptr dst_cell Abi.binding_field_item in
    let dst_pair_binding_cell = get_element_ptr dst_cell Abi.binding_field_binding in

      mov dst_pair_item_cell (crate_rel_imm fix);
      mov dst_pair_binding_cell zero


  and trans_init_structural_from_atoms
      (dst:Il.cell)
      (dst_slots:Ast.slot array)
      (atoms:Ast.atom array)
      : unit =
    Array.iteri
      begin
        fun i atom ->
          trans_init_slot_from_atom
            CLONE_none
            (get_element_ptr dst i)
            dst_slots.(i)
            atom
      end
      atoms

  and trans_init_rec_update
      (dst:Il.cell)
      (dst_slots:Ast.slot array)
      (trec:Ast.ty_rec)
      (atab:(Ast.ident * Ast.mode * Ast.atom) array)
      (base:Ast.lval)
      : unit =
    Array.iteri
      begin
        fun i (fml_ident, _) ->
          let fml_entry _ (act_ident, _, atom) =
            if act_ident = fml_ident then Some atom else None
          in
          let slot = dst_slots.(i) in
            match arr_search atab fml_entry with
                Some atom ->
                  trans_init_slot_from_atom
                    CLONE_none
                    (get_element_ptr dst i)
                    slot
                    atom
              | None ->
                  let (src, _) = trans_lval base in
                    trans_copy_slot
                      true
                      (get_element_ptr dst i) slot
                      (get_element_ptr src i) slot
                      None
      end
      trec

  and trans_init_slot_from_atom
      (clone:clone_ctrl)
      (dst:Il.cell) (dst_slot:Ast.slot)
      (atom:Ast.atom)
      : unit =
    let is_alias_cell =
      match dst_slot.Ast.slot_mode with
          Ast.MODE_read_alias
        | Ast.MODE_write_alias -> true
        | _ -> false
    in
      match atom with
        | Ast.ATOM_literal _ ->
            let src = trans_atom atom in
              if is_alias_cell
              then
                match clone with
                    CLONE_none ->
                      (* 
                       * FIXME: this won't work on write aliases, it
                       * doesn't know to reload. Try something
                       * else.
                       *)
                      mov dst (Il.Cell (alias (Il.Mem (force_to_mem src))))
                  | _ ->
                      bug () "attempting to clone alias cell"
              else
                mov (deref_slot true dst dst_slot) src
        | Ast.ATOM_lval src_lval ->
            let (src, src_slot) = trans_lval src_lval in
              trans_init_slot_from_cell clone dst dst_slot src src_slot

  and trans_init_slot_from_cell
      (clone:clone_ctrl)
      (dst:Il.cell) (dst_slot:Ast.slot)
      (src:Il.cell) (src_slot:Ast.slot)
      : unit =
    assert (slot_ty src_slot = slot_ty dst_slot);
    let is_alias_cell =
      match dst_slot.Ast.slot_mode with
          Ast.MODE_read_alias
        | Ast.MODE_write_alias -> true
        | _ -> false
    in
      match clone with
          CLONE_chan clone_task ->
            let clone =
              if (type_contains_chan (slot_ty src_slot))
              then CLONE_all clone_task
              else CLONE_none
            in
              trans_init_slot_from_cell clone dst dst_slot src src_slot
        | CLONE_none ->
            if is_alias_cell
            then mov dst (Il.Cell (alias src))
            else trans_copy_slot true dst dst_slot src src_slot None
        | CLONE_all clone_task ->
            if is_alias_cell
            then bug () "attempting to clone alias cell"
            else clone_slot clone_task dst src dst_slot None

  and trans_be_fn
      (cx:ctxt)
      (dst_cell:Il.cell)
      (flv:Ast.lval)
      (args:Ast.atom array)
      : unit =
    let (ptr, fn_ty) = trans_callee flv in
    let cc = call_ctrl flv in
    let call = { call_ctrl = cc;
                 call_callee_ptr = ptr;
                 call_callee_ty = fn_ty;
                 call_callee_ty_params = [| |];
                 call_output = dst_cell;
                 call_args = args;
                 call_iterator_args = call_iterator_args None;
                 call_indirect_args = call_indirect_args flv cc }
    in
      (* FIXME: true if caller is object fn *)
    let caller_is_closure = false in
      log cx "trans_be_fn: %s call to lval %a"
        (call_ctrl_string cc) Ast.sprintf_lval flv;
      trans_be (fun () -> Ast.sprintf_lval () flv) caller_is_closure call

  and trans_prepare_fn_call
      (initializing:bool)
      (cx:ctxt)
      (dst_cell:Il.cell)
      (flv:Ast.lval)
      (ty_params:Ast.ty array)
      (fco:foreach_ctrl option)
      (args:Ast.atom array)
      : Il.operand =
    let (ptr, fn_ty) = trans_callee flv in
    let cc = call_ctrl flv in
    let call = { call_ctrl = cc;
                 call_callee_ptr = ptr;
                 call_callee_ty = fn_ty;
                 call_callee_ty_params = ty_params;
                 call_output = dst_cell;
                 call_args = args;
                 call_iterator_args = call_iterator_args fco;
                 call_indirect_args = call_indirect_args flv cc }
    in
      iflog
        begin
          fun _ ->
            log cx "trans_prepare_fn_call: %s call to lval %a"
              (call_ctrl_string cc) Ast.sprintf_lval flv;
            log cx "lval type: %a" Ast.sprintf_ty fn_ty;
            Array.iteri (fun i t -> log cx "ty param %d = %a"
                           i Ast.sprintf_ty t)
              ty_params;
        end;
      trans_prepare_call initializing (fun () -> Ast.sprintf_lval () flv) call

  and trans_call_pred_and_check
      (constr:Ast.constr)
      (flv:Ast.lval)
      (args:Ast.atom array)
      : unit =
    let (ptr, fn_ty) = trans_callee flv in
    let dst_cell = Il.Mem (force_to_mem imm_false) in
    let call = { call_ctrl = call_ctrl flv;
                 call_callee_ptr = ptr;
                 call_callee_ty = fn_ty;
                 call_callee_ty_params = [| |];
                 call_output = dst_cell;
                 call_args = args;
                 call_iterator_args = [| |];
                 call_indirect_args = [| |] }
    in
      iflog (fun _ -> annotate "predicate call");
      let fn_ptr =
        trans_prepare_call true (fun _ -> Ast.sprintf_lval () flv) call
      in
        call_code (code_of_operand fn_ptr);
        iflog (fun _ -> annotate "predicate check/fail");
        let jmp = trans_compare Il.JE (Il.Cell dst_cell) imm_true in
        let errstr = Printf.sprintf "predicate check: %a"
          Ast.sprintf_constr constr
        in
          trans_cond_fail errstr jmp

  and trans_init_closure
      (closure_cell:Il.cell)
      (target_fn_ptr:Il.operand)
      (target_binding_ptr:Il.operand)
      (bound_arg_slots:Ast.slot array)
      (bound_args:Ast.atom array)
      : unit =

    let rc_cell = get_element_ptr closure_cell 0 in
    let targ_cell = get_element_ptr closure_cell 1 in
    let args_cell = get_element_ptr closure_cell 2 in

    iflog (fun _ -> annotate "init closure refcount");
    mov rc_cell one;
    iflog (fun _ -> annotate "set closure target code ptr");
    mov (get_element_ptr targ_cell 0) (reify_ptr target_fn_ptr);
    iflog (fun _ -> annotate "set closure target binding ptr");
    mov (get_element_ptr targ_cell 1) (reify_ptr target_binding_ptr);

    iflog (fun _ -> annotate "set closure bound args");
    copy_bound_args args_cell bound_arg_slots bound_args

  and trans_bind_fn
      (initializing:bool)
      (cc:call_ctrl)
      (bind_id:node_id)
      (dst:Ast.lval)
      (flv:Ast.lval)
      (fn_sig:Ast.ty_sig)
      (args:Ast.atom option array)
      : unit =
    let (dst_cell, _) = trans_lval_maybe_init initializing dst in
    let (target_ptr, _) = trans_callee flv in
    let arg_bound_flags = Array.map bool_of_option args in
    let arg_slots =
      arr_map2
        (fun arg_slot bound_flag ->
           if bound_flag then Some arg_slot else None)
        fn_sig.Ast.sig_input_slots
        arg_bound_flags
    in
    let bound_arg_slots = arr_filter_some arg_slots in
    let bound_args = arr_filter_some args in
    let glue_fixup =
      get_fn_binding_glue bind_id fn_sig.Ast.sig_input_slots arg_bound_flags
    in
    let target_fn_ptr = callee_fn_ptr target_ptr cc in
    let target_binding_ptr = callee_binding_ptr flv cc in
    let closure_rty = closure_referent_type bound_arg_slots in
    let closure_sz = force_sz (Il.referent_ty_size word_bits closure_rty) in
    let fn_cell = get_element_ptr dst_cell Abi.binding_field_item in
    let closure_cell =
      ptr_cast
        (get_element_ptr dst_cell Abi.binding_field_binding)
        (Il.ScalarTy (Il.AddrTy (closure_rty)))
    in
      iflog (fun _ -> annotate "assign glue-code to fn slot of pair");
      mov fn_cell (crate_rel_imm glue_fixup);
      iflog (fun _ -> annotate "heap-allocate closure to binding slot of pair");
      trans_malloc closure_cell closure_sz;
      trans_init_closure
        (deref closure_cell)
        target_fn_ptr target_binding_ptr
        bound_arg_slots bound_args


  and trans_arg0 (arg_cell:Il.cell) (output_cell:Il.cell) : unit =
    (* Emit arg0 of any call: the output slot. *)
    iflog (fun _ -> annotate "fn-call arg 0: output slot");
    trans_init_slot_from_cell
      CLONE_none
      arg_cell (word_write_alias_slot abi)
      output_cell word_slot

  and trans_arg1 (arg_cell:Il.cell) : unit =
    (* Emit arg1 of any call: the task pointer. *)
    iflog (fun _ -> annotate "fn-call arg 1: task pointer");
    trans_init_slot_from_cell
      CLONE_none
      arg_cell word_slot
      abi.Abi.abi_tp_cell word_slot

  and trans_argN
      (clone:clone_ctrl)
      (arg_cell:Il.cell)
      (arg_slot:Ast.slot)
      (arg:Ast.atom)
      : unit =
    trans_init_slot_from_atom clone arg_cell arg_slot arg

  and code_of_cell (cell:Il.cell) : Il.code =
    match cell with
        Il.Mem (_, Il.ScalarTy (Il.AddrTy Il.CodeTy))
      | Il.Reg (_, Il.AddrTy Il.CodeTy) -> Il.CodePtr (Il.Cell cell)
      | _ ->
          bug () "expected code-pointer cell, found %s"
            (Il.string_of_cell abi.Abi.abi_str_of_hardreg cell)

  and code_of_operand (operand:Il.operand) : Il.code =
    match operand with
        Il.Cell c -> code_of_cell c
      | Il.ImmPtr (_, Il.CodeTy) -> Il.CodePtr operand
      | _ ->
          bug () "expected code-pointer operand, got %s"
            (Il.string_of_operand abi.Abi.abi_str_of_hardreg operand)

  and ty_arg_slots (ty:Ast.ty) : Ast.slot array =
    match ty with
        Ast.TY_fn (tsig, _) -> tsig.Ast.sig_input_slots
      | Ast.TY_pred (args, _) -> args
      | _ -> bug () "Trans.ty_arg_slots on non-callable type: %a"
          Ast.sprintf_ty ty

  and copy_fn_args
      (tail_area:bool)
      (clone:clone_ctrl)
      (call:call)
      : unit =

    let n_ty_params = Array.length call.call_callee_ty_params in
    let all_callee_args_rty =
      if call.call_ctrl = CALL_direct
      then call_args_referent_type cx n_ty_params call.call_callee_ty None
      else call_args_referent_type cx n_ty_params call.call_callee_ty (Some Il.OpaqueTy)
    in
    let all_callee_args_cell = callee_args_cell tail_area all_callee_args_rty in

    let _ = iflog (fun _ -> annotate
                     (Printf.sprintf
                        "copying fn args to %d-ty-param call with rty: %s\n"
                        n_ty_params (Il.string_of_referent_ty all_callee_args_rty)))
    in
    let callee_arg_slots = ty_arg_slots call.call_callee_ty in
    let callee_output_cell =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_out_ptr
    in
    let callee_task_cell =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_task_ptr
    in
    let callee_ty_params =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_ty_params
    in
    let callee_args =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_args
    in
    let callee_iterator_args =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_iterator_args
    in
    let callee_indirect_args =
      get_element_ptr all_callee_args_cell Abi.calltup_elt_indirect_args
    in

    let n_args = Array.length call.call_args in
    let n_iterators = Array.length call.call_iterator_args in
    let n_indirects = Array.length call.call_indirect_args in

      trans_arg0 callee_output_cell call.call_output;
      trans_arg1 callee_task_cell;

      let get_tydesc ty_param =
        match ty_param with
            Ast.TY_param (idx, _) ->
              (alias (get_current_fn_ty_desc idx))
          | _ ->
              (crate_rel_to_ptr (trans_tydesc ty_param) Il.OpaqueTy)
      in

      Array.iteri
        begin
          fun i ty_param ->
            iflog (fun _ ->
                     annotate
                       (Printf.sprintf "fn-call ty param %d of %d"
                          i n_ty_params));
            trans_init_slot_from_cell CLONE_none
              (get_element_ptr callee_ty_params i) word_slot
              (get_tydesc ty_param) word_slot
        end
        call.call_callee_ty_params;

      Array.iteri
        begin
          fun i arg_atom ->
            iflog (fun _ ->
                     annotate
                       (Printf.sprintf "fn-call arg %d of %d (+ %d indirect)"
                          i n_args n_indirects));
            trans_argN
              clone
              (get_element_ptr callee_args i)
              callee_arg_slots.(i)
              arg_atom
        end
        call.call_args;

      Array.iteri
        begin
          fun i iterator_arg_operand ->
            iflog (fun _ ->
                     annotate (Printf.sprintf "fn-call iterator-arg %d of %d"
                                 i n_iterators));
            mov (get_element_ptr callee_iterator_args i) iterator_arg_operand
        end
        call.call_iterator_args;

      Array.iteri
        begin
          fun i indirect_arg_operand ->
            iflog (fun _ ->
                     annotate (Printf.sprintf "fn-call indirect-arg %d of %d"
                                 i n_indirects));
            mov (get_element_ptr callee_indirect_args i) indirect_arg_operand
        end
        call.call_indirect_args


  and call_code (code:Il.code) : unit =
    let vr = next_vreg_cell Il.voidptr_t in
      emit (Il.call vr code);


  and copy_bound_args
      (dst_cell:Il.cell)
      (bound_arg_slots:Ast.slot array)
      (bound_args:Ast.atom array)
      : unit =
    let n_slots = Array.length bound_arg_slots in
      Array.iteri
        begin
          fun i slot ->
            iflog (fun _ ->
                     annotate (Printf.sprintf
                                 "copy bound arg %d of %d" i n_slots));
            trans_argN CLONE_none
              (get_element_ptr dst_cell i)
              slot bound_args.(i)
        end
        bound_arg_slots

  and merge_bound_args
      (all_self_args_rty:Il.referent_ty)
      (all_callee_args_rty:Il.referent_ty)
      (arg_slots:Ast.slot array)
      (arg_bound_flags:bool array)
      : unit =
    begin
      (* 
       * NB: 'all_*_args', both self and callee, are always 4-tuples: 
       * 
       *    [out_ptr, task_ptr, [args], [indirect_args]] 
       * 
       * The first few bindings here just destructure those via GEP.
       * 
       *)
      let all_self_args_cell = caller_args_cell all_self_args_rty in
      let all_callee_args_cell = callee_args_cell false all_callee_args_rty in

      let self_args_cell =
        get_element_ptr all_self_args_cell Abi.calltup_elt_args
      in
      let callee_args_cell =
        get_element_ptr all_callee_args_cell Abi.calltup_elt_args
      in
      let self_indirect_args_cell =
        get_element_ptr all_self_args_cell Abi.calltup_elt_indirect_args
      in

      let n_args = Array.length arg_bound_flags in
      let bound_i = ref 0 in
      let unbound_i = ref 0 in

        iflog (fun _ -> annotate "copy out-ptr");
        mov
          (get_element_ptr all_callee_args_cell Abi.calltup_elt_out_ptr)
          (Il.Cell (get_element_ptr all_self_args_cell
                      Abi.calltup_elt_out_ptr));

        iflog (fun _ -> annotate "copy task-ptr");
        mov
          (get_element_ptr all_callee_args_cell Abi.calltup_elt_task_ptr)
          (Il.Cell (get_element_ptr all_self_args_cell
                      Abi.calltup_elt_task_ptr));

        iflog (fun _ -> annotate "extract closure indirect-arg");
        let closure_cell =
          deref (get_element_ptr self_indirect_args_cell
                   Abi.indirect_args_elt_closure)
        in
        let closure_args_cell = get_element_ptr closure_cell 2 in

          for arg_i = 0 to (n_args - 1) do
            let dst_cell = get_element_ptr callee_args_cell arg_i in
            let slot = arg_slots.(arg_i) in
            let is_bound = arg_bound_flags.(arg_i) in
            let src_cell =
              if is_bound then
                begin
                  iflog (fun _ -> annotate
                           (Printf.sprintf
                              "extract bound arg %d as actual arg %d"
                              !bound_i arg_i));
                  get_element_ptr closure_args_cell (!bound_i);
                end
              else
                begin
                  iflog (fun _ -> annotate
                           (Printf.sprintf
                              "extract unbound arg %d as actual arg %d"
                              !unbound_i arg_i));
                  get_element_ptr self_args_cell (!unbound_i);
                end
            in
              iflog (fun _ -> annotate
                       (Printf.sprintf
                          "copy into actual-arg %d" arg_i));
              trans_copy_slot true dst_cell slot src_cell slot None;
              incr (if is_bound then bound_i else unbound_i);
          done;
          assert ((!bound_i + !unbound_i) == n_args)
    end


  and callee_fn_ptr
      (fptr:Il.operand)
      (cc:call_ctrl)
      : Il.operand =
    match cc with
        CALL_direct
      | CALL_vtbl -> fptr
      | CALL_indirect ->
          (* fptr is a pair [disp, binding*] *)
          let pair_cell = need_cell (reify_ptr fptr) in
          let disp_cell = get_element_ptr pair_cell Abi.binding_field_item in
            Il.Cell (crate_rel_to_ptr (Il.Cell disp_cell) Il.CodeTy)

  and callee_binding_ptr
      (pair_lval:Ast.lval)
      (cc:call_ctrl)
      : Il.operand =
    if cc = CALL_direct
    then zero
    else
      let (pair_cell, _) = trans_lval pair_lval in
        Il.Cell (get_element_ptr pair_cell Abi.binding_field_binding)

  and call_ctrl flv : call_ctrl =
    if lval_is_static cx flv
    then CALL_direct
    else
      if lval_is_obj_vtbl cx flv
      then CALL_vtbl
      else CALL_indirect

  and call_ctrl_string cc =
    match cc with
        CALL_direct -> "direct"
      | CALL_indirect -> "indirect"
      | CALL_vtbl -> "vtbl"

  and call_iterator_args
      (fco:foreach_ctrl option)
      : Il.operand array =
    match fco with
        None -> [| |]
      | Some fc ->
          begin
            iflog (fun _ -> annotate "calculate iterator args");
            abi.Abi.abi_iterator_args (emitter ()) fc.foreach_fixup fc.foreach_depth
          end

  and call_indirect_args
      (flv:Ast.lval)
      (cc:call_ctrl)
      : Il.operand array =
      begin
        match cc with
            CALL_direct -> [| |]
          | CALL_indirect -> [| callee_binding_ptr flv cc |]
          | CALL_vtbl ->
              begin
                match flv with
                    (* 
                     * FIXME: will need to pass both words of obj if we add
                     * a 'self' value for self-dispatch within objs.
                     *)
                    Ast.LVAL_ext (base, _) -> [| callee_binding_ptr base cc |]
                  | _ -> bug (lval_base_id flv) "call_indirect_args on obj-fn without base obj"
              end
      end

  and trans_be
      (logname:(unit -> string))
      (caller_is_closure:bool)
      (call:call)
      : unit =
    let callee_fptr = callee_fn_ptr call.call_callee_ptr call.call_ctrl in
    let callee_code = code_of_operand callee_fptr in
    let callee_args_rty =
      call_args_referent_type cx 0 call.call_callee_ty
        (if call.call_ctrl = CALL_direct then None else (Some Il.OpaqueTy))
    in
    let callee_argsz =
      force_sz (Il.referent_ty_size word_bits callee_args_rty)
    in
    let closure_rty =
      if caller_is_closure
      then Some Il.OpaqueTy
      else None
    in
    let caller_args_rty = current_fn_args_rty closure_rty in
    let
        caller_argsz = force_sz (Il.referent_ty_size word_bits caller_args_rty)
    in
      iflog (fun _ -> annotate
               (Printf.sprintf "copy args for tail call to %s" (logname ())));
      copy_fn_args true CLONE_none call;
      iter_frame_and_arg_slots (current_fn ()) callee_drop_slot;
      abi.Abi.abi_emit_fn_tail_call (emitter())
        (force_sz (current_fn_callsz())) caller_argsz callee_code callee_argsz;


  and trans_prepare_call
      ((*initializing*)_:bool)
      (logname:(unit -> string))
      (call:call)
      : Il.operand =

    let callee_fptr = callee_fn_ptr call.call_callee_ptr call.call_ctrl in
      iflog (fun _ -> annotate
               (Printf.sprintf "copy args for call to %s" (logname ())));
      copy_fn_args false CLONE_none call;
      iflog (fun _ -> annotate (Printf.sprintf "call %s" (logname ())));
      (* FIXME (bug 541535 ): we need to actually handle writing to an
       * already-initialised slot. Currently we blindly assume we're
       * initializing, overwrite the slot; this is ok if we're writing
       * to an interior output slot, but we'll leak any exteriors as we
       * do that.  *)
      callee_fptr

  (* FIXME: eliminate this, it duplicates logic elsewhere. *)
  and arg_tup_cell
      (arg_slots:Ast.slot array)
      : Il.cell =
    let mem = sp_imm 0L in
    let ty = Ast.TY_tup (fn_call_tup abi arg_slots) in
    let rty = referent_type abi ty in
      Il.Mem (mem, rty)

  and callee_drop_slot
      (_:Ast.slot_key)
      (slot_id:node_id)
      (slot:Ast.slot)
      : unit =
    drop_slot (cell_of_block_slot slot_id) slot None


  and trans_alt_tag { Ast.alt_tag_lval = lval; Ast.alt_tag_arms = arms } =
    let ((lval_cell:Il.cell), { Ast.slot_mode = _; Ast.slot_ty = ty }) =
      trans_lval lval
    in
    let ty_tag : Ast.ty_tag =
      match ty with
          Some (Ast.TY_tag tag_ty) -> tag_ty
        | Some (Ast.TY_iso { Ast.iso_index = i; Ast.iso_group = g }) -> g.(i)
        | _ -> bug cx "expected tag ty"
    in
    let tag_keys = sorted_htab_keys ty_tag in
    let tag_cell:Il.cell = get_element_ptr lval_cell 0 in
    let union_cell:Il.cell = get_element_ptr lval_cell 1 in
    let trans_arm
        { node = ((tag_id:Ast.ident), slots, (block:Ast.block)) } : quad_idx =
      let tag_name = Ast.NAME_base (Ast.BASE_ident tag_id) in
      let tag_number = arr_idx tag_keys tag_name in
      emit (Il.cmp (Il.Cell tag_cell) (imm (Int64.of_int tag_number)));
      let next_jump = mark() in
      emit (Il.jmp Il.JNE Il.CodeNone);
      let tup_cell:Il.cell = get_variant_ptr union_cell tag_number in
      let trans_dst idx ({ node = dst_slot; id = dst_id }, _) =
        let dst_cell = cell_of_block_slot dst_id in
        let src_operand = Il.Cell (get_element_ptr tup_cell idx) in
        mov (deref_slot true dst_cell dst_slot) src_operand
      in
      Array.iteri trans_dst slots;
      trans_block block;
      let last_jump = mark() in
      emit (Il.jmp Il.JMP Il.CodeNone);
      patch next_jump;
      last_jump
    in
    let last_jumps = Array.map trans_arm arms in
    Array.iter patch last_jumps

  and trans_stmt (stmt:Ast.stmt) : unit =
    (* Helper to localize errors by stmt, at minimum. *)
    try
      iflog
        begin
          fun _ ->
            annotate (Ast.fmt_to_str Ast.fmt_stmt_body stmt)
        end;
      curr_stmt := Some stmt.id;
      trans_stmt_full stmt;
      curr_stmt := None
    with
        Semant_err (None, msg) -> raise (Semant_err ((Some stmt.id), msg))


  and maybe_init (id:node_id) (action:string) (dst:Ast.lval) : bool =
    let b = Hashtbl.mem cx.ctxt_copy_stmt_is_init id in
    let act = if b then ("initializing-" ^ action) else action in
      iflog
        (fun _ ->
           annotate (Printf.sprintf "%s on dst lval %a"
                       act Ast.sprintf_lval dst));
      b

  and trans_set_outptr (at:Ast.atom) : unit =
    let (dst_mem, _) =
      need_mem_cell
        (deref (wordptr_at (fp_imm out_mem_disp)))
    in
    let atom_ty = atom_type cx at in
    let dst_slot = interior_slot atom_ty in
    let dst_ty = referent_type abi atom_ty in
    let dst_cell = Il.Mem (dst_mem, dst_ty) in
      trans_init_slot_from_atom
        CLONE_none dst_cell dst_slot at

  and trans_foreach_body
      (depth:int)
      (it_ptr_cell:Il.cell)
      (body:Ast.block)
      : unit =
    let get_callsz () =
      calculate_sz_in_current_frame (current_fn_callsz ())
    in
      begin
        abi.Abi.abi_emit_iteration_prologue (emitter ()) nabi_rust (upcall_fixup "upcall_grow_task") get_callsz;
        trans_block body;
        abi.Abi.abi_emit_iteration_epilogue (emitter ()) depth it_ptr_cell;
      end

  and trans_stmt_full (stmt:Ast.stmt) : unit =
    match stmt.node with

        Ast.STMT_log a ->
          begin
            match atom_type cx a with
                (* NB: If you extend this, be sure to update the
                 * typechecking code in type.ml as well. *)
                Ast.TY_str -> trans_log_str a
              | Ast.TY_int | Ast.TY_bool | Ast.TY_char | Ast.TY_mach (TY_u8)
              | Ast.TY_mach (TY_u16) | Ast.TY_mach (TY_u32)
              | Ast.TY_mach (TY_s8) | Ast.TY_mach (TY_s16)
              | Ast.TY_mach (TY_s32) ->
                  trans_log_int a
              | _ -> bugi cx stmt.id "unimplemented logging type"
          end

      | Ast.STMT_check_expr e ->
          begin
            match expr_type cx e with
                Ast.TY_bool -> trans_check_expr e
              | _ -> bugi cx stmt.id "check expr on non-bool"
          end

      | Ast.STMT_yield ->
          trans_yield ()

      | Ast.STMT_fail ->
          trans_fail ()

      | Ast.STMT_join task ->
          trans_join task

      | Ast.STMT_send (chan,src) ->
          trans_send chan src

      | Ast.STMT_spawn (dst, domain, plv, args) ->
          trans_spawn (maybe_init stmt.id "spawn" dst) dst domain plv args

      | Ast.STMT_recv (dst, chan) ->
          trans_recv (maybe_init stmt.id "recv" dst) dst chan

      | Ast.STMT_copy (dst, e_src) ->
          trans_copy (maybe_init stmt.id "copy" dst) dst e_src

      | Ast.STMT_copy_binop (dst, binop, a_src) ->
          begin
            let initializing = (maybe_init stmt.id "copy" dst) in
            let (dst_cell, dst_slot) = trans_lval_maybe_init initializing dst in
              match slot_ty dst_slot with
                  Ast.TY_str ->
                    trans_upcall "upcall_str_concat" dst_cell
                      [| Il.Cell dst_cell;
                         Il.Cell dst_cell;
                         (trans_atom a_src); |]
                | _ ->
                    ignore (trans_binary binop
                              (Il.Cell (deref_slot false dst_cell dst_slot))
                              (trans_atom a_src))
          end

      | Ast.STMT_call (dst, flv, args) ->
          begin
            let init = maybe_init stmt.id "call" dst in
            let ty = lval_ty cx flv in
            let ty_params =
              match htab_search cx.ctxt_call_lval_params (lval_base_id flv) with
                  Some params -> params
                | None -> [| |]
            in
              match ty with
                  Ast.TY_fn _
                | Ast.TY_pred _ ->
                    let (dst_cell, _) = trans_lval_maybe_init init dst in
                    let fn_ptr =
                      trans_prepare_fn_call init cx dst_cell flv ty_params None args
                    in
                      call_code (code_of_operand fn_ptr)
                | _ -> bug () "Calling unexpected lval."
          end

      | Ast.STMT_bind (dst, flv, args) ->
          begin
            let init = maybe_init stmt.id "bind" dst in
              match lval_ty cx flv with
                  Ast.TY_fn (tsig, _) ->
                    trans_bind_fn
                      init (call_ctrl flv) stmt.id dst flv tsig args
                      (* FIXME (bug 544382): implement bind for objs *)
                | _ -> bug () "Binding unexpected lval."
          end

      | Ast.STMT_init_rec (dst, atab, base) ->
          let (slot_cell, slot) = trans_lval_init dst in
          let (trec, dst_slots) =
            match slot_ty slot with
                Ast.TY_rec trec -> (trec, Array.map snd trec)
              | _ -> bugi cx stmt.id "non-rec destination type in stmt_init_rec"
          in
          let dst_cell = deref_slot true slot_cell slot in
            begin
              match base with
                  None ->
                    let atoms = Array.map (fun (_, _, atom) -> atom) atab in
                      trans_init_structural_from_atoms dst_cell dst_slots atoms
                | Some base_lval ->
                    trans_init_rec_update dst_cell dst_slots trec atab base_lval
            end

      | Ast.STMT_init_tup (dst, mode_atoms) ->
          let (slot_cell, slot) = trans_lval_init dst in
          let dst_slots =
            match slot_ty slot with
                Ast.TY_tup ttup -> ttup
              | _ -> bugi cx stmt.id "non-tup destination type in stmt_init_tup"
          in
          let atoms = Array.map (fun (_, atom) -> atom) mode_atoms in
          let dst_cell = deref_slot true slot_cell slot in
            trans_init_structural_from_atoms dst_cell dst_slots atoms


      | Ast.STMT_init_str (dst, s) ->
          trans_init_str dst s

      | Ast.STMT_init_vec (dst, _, atoms) ->
          trans_init_vec dst atoms

      | Ast.STMT_init_port dst ->
          trans_init_port dst

      | Ast.STMT_init_chan (dst, port) ->
          begin
            match port with
                None ->
                  let (dst_cell, _) =
                    trans_lval_init dst
                  in
                    mov dst_cell imm_false
              | Some p ->
                  trans_init_chan dst p
          end

      | Ast.STMT_block block ->
          trans_block block

      | Ast.STMT_while sw ->
          let (head_stmts, head_expr) = sw.Ast.while_lval in
          let fwd_jmp = mark () in
            emit (Il.jmp Il.JMP Il.CodeNone);
            let block_begin = mark () in
              trans_block sw.Ast.while_body;
              patch fwd_jmp;
              Array.iter trans_stmt head_stmts;
              let back_jmps = trans_cond false head_expr in
                List.iter (fun j -> patch_existing j block_begin) back_jmps;

      | Ast.STMT_if si ->
          let skip_thn_jmps = trans_cond true si.Ast.if_test in
            trans_block si.Ast.if_then;
            begin
              match si.Ast.if_else with
                  None -> List.iter patch skip_thn_jmps
                | Some els ->
                    let skip_els_jmp = mark () in
                      begin
                        emit (Il.jmp Il.JMP Il.CodeNone);
                        List.iter patch skip_thn_jmps;
                        trans_block els;
                        patch skip_els_jmp
                      end
            end

      | Ast.STMT_check (preds, calls) ->
          Array.iteri
            (fun i (fn, args) -> trans_call_pred_and_check preds.(i) fn args)
            calls

      | Ast.STMT_ret (proto_opt, atom_opt) ->
          begin
          match proto_opt with
              None ->
                begin
                  begin
                    match atom_opt with
                        None -> ()
                      | Some at -> trans_set_outptr at
                  end;
                  Stack.push (mark()) (Stack.top epilogue_jumps);
                end;
                emit (Il.jmp Il.JMP Il.CodeNone)
            | Some _ ->
                bugi cx stmt.id "ret{?,!,*,+} unhandled in trans_stmt %a"
                  Ast.sprintf_stmt stmt
          end

      | Ast.STMT_be (proto_opt, flv, args) ->
          begin
            match proto_opt with
                None ->
                  begin
                    let ty = lval_ty cx flv in
                      match ty with
                          Ast.TY_fn (tsig, _) ->
                            let result_ty = slot_ty tsig.Ast.sig_output_slot in
                            let (dst_mem, _) =
                              need_mem_cell
                                (deref (wordptr_at (fp_imm out_mem_disp)))
                            in
                            let dst_rty = referent_type abi result_ty in
                            let dst_cell = Il.Mem (dst_mem, dst_rty) in
                              trans_be_fn cx dst_cell flv args

                        | Ast.TY_pred _ ->
                            bug () "be pred not yet implemented"

                        | _ -> bug () "Calling unexpected lval."
                  end
              | Some _ ->
                  bugi cx stmt.id "be{?,!,*,+} unhandled in trans_stmt %a"
                    Ast.sprintf_stmt stmt
          end

      | Ast.STMT_put (proto_opt, atom_opt) ->
          begin
            match proto_opt with
                None ->
                  begin
                    begin
                      match atom_opt with
                          None -> ()
                        | Some at -> trans_set_outptr at
                    end;
                    (* FIXME: might I be a closure? if so, then Some ... *)
                    abi.Abi.abi_emit_put (emitter ()) (current_fn_args_rty None)
                  end
              | Some _ ->
                  bugi cx stmt.id "put{?,!,*,+} unhandled in trans_stmt %a"
                    Ast.sprintf_stmt stmt
          end

      | Ast.STMT_alt_tag stmt_alt_tag -> trans_alt_tag stmt_alt_tag

      | Ast.STMT_decl _ -> ()

      | Ast.STMT_foreach fe ->
          let (dst_slot, _) = fe.Ast.foreach_slot in
          let dst_cell = cell_of_block_slot dst_slot.id in
          let (flv, args) = fe.Ast.foreach_call in
          let ty_params =
            match htab_search cx.ctxt_call_lval_params (lval_base_id flv) with
                Some params -> params
              | None -> [| |]
          in
          let depth = Hashtbl.find cx.ctxt_loop_depths stmt.id in
          let fn_depth = Hashtbl.find cx.ctxt_fn_loop_depths (current_fn ()) in
          let body_fixup = new_fixup "foreach loop body" in
          let fc = { foreach_fixup = body_fixup; foreach_depth = depth } in
          let it_ptr_reg = next_vreg () in
          let it_ptr_cell = Il.Reg (it_ptr_reg, Il.AddrTy Il.CodeTy) in
            begin
              iflog (fun _ ->
                       log cx "for-each at depth %d in fn of depth %d\n" depth fn_depth);
              let fn_ptr = reify_ptr (trans_prepare_fn_call true cx dst_cell flv ty_params (Some fc) args) in

                mov it_ptr_cell fn_ptr;                                      (* p <- &fn *)
                abi.Abi.abi_emit_loop_prologue (emitter ()) depth;           (* save stack pointer *)
                let jmp = mark () in
                  emit (Il.jmp Il.JMP Il.CodeNone);                          (* jump L2 *)

                  emit (Il.Enter body_fixup);                                (* L1: *)
                  trans_foreach_body depth it_ptr_cell fe.Ast.foreach_body;  (* loop body *)
                  patch jmp;                                                 (* L2: *)
                  call_code (code_of_operand (Il.Cell it_ptr_cell));         (* call p *)
                  emit Il.Leave;

                  abi.Abi.abi_emit_loop_epilogue (emitter ()) depth;         (* restore stack pointer *)
            end

      | _ -> bugi cx stmt.id "unhandled form of statement in trans_stmt %a"
          Ast.sprintf_stmt stmt

  and capture_emitted_quads (fix:fixup) (node:node_id) : unit =
    let e = emitter() in
    let n_vregs = Il.num_vregs e in
    let quads = emitted_quads e in
    let name = path_name () in
    let f =
      if Stack.is_empty curr_file
      then bugi cx node "Missing file scope when capturing quads."
      else Stack.top curr_file
    in
    let item_code = Hashtbl.find cx.ctxt_file_code f in
      begin
        iflog (fun _ ->
                 log cx "capturing quads for item #%d" (int_of_node node);
                 annotate_quads name);
        let vr_s =
          match htab_search cx.ctxt_spill_fixups node with
              None -> (assert (n_vregs = 0); None)
            | Some spill -> Some (n_vregs, spill)
        in
        let loop_depth = Int64.of_int (Hashtbl.find cx.ctxt_fn_loop_depths node) in
        let spill_disp = Int64.mul loop_depth (cx.ctxt_abi.Abi.abi_loop_info_sz) in
        let code = { code_fixup = fix;
                     code_quads = quads;
                     code_vregs_and_spill = vr_s;
                     code_spill_disp = spill_disp }
        in
          htab_put item_code node code;
          htab_put cx.ctxt_all_item_code node code
      end

  and get_frame_glue_fns (fnid:node_id) : Il.operand =
    let get_frame_glue glue inner =
      get_mem_glue glue
        begin
          fun mem ->
            iter_frame_and_arg_slots fnid
              begin
                fun key slot_id slot ->
                  match htab_search cx.ctxt_slot_offsets slot_id with
                      Some off when not (slot_is_obj_state cx slot_id) ->
                        let referent_type = slot_id_referent_type slot_id in
                        let (fp, st) =
                          force_to_reg (Il.Cell (rty_ptr_at mem referent_type))
                        in
                        let slot_cell =
                          deref_off_sz fp fnid (Il.Reg (fp,st)) off
                        in
                          inner key slot_id slot slot_cell
                    | _ -> ()
              end
        end
    in
    trans_crate_rel_data_operand
      (DATA_frame_glue_fns fnid)
      begin
        fun _ ->
          let mark_frame_glue_fixup =
            get_frame_glue (GLUE_mark_frame fnid)
              begin
                fun _ _ slot slot_cell ->
                  mark_slot slot_cell slot None
              end
          in
          let drop_frame_glue_fixup =
            get_frame_glue (GLUE_drop_frame fnid)
              begin
                fun _ _ slot slot_cell ->
                  drop_slot slot_cell slot None
              end
          in
          let reloc_frame_glue_fixup =
            get_frame_glue (GLUE_reloc_frame fnid)
              begin
                fun _ _ _ _ ->
                  ()
              end
          in
            table_of_crate_rel_fixups
              [|
               (* 
                * NB: this must match the struct-offsets given in ABI
                * & rust runtime library.
                *)
                mark_frame_glue_fixup;
                drop_frame_glue_fixup;
                reloc_frame_glue_fixup;
              |]
      end
  in

  let trans_frame_entry (fnid:node_id) (proto_opt:Ast.proto option) : unit =
    let framesz = get_framesz cx fnid in
    let callsz = get_callsz cx fnid in
      Stack.push (Stack.create()) epilogue_jumps;
      push_new_emitter_with_vregs ();
      iflog (fun _ -> annotate "prologue");
      abi.Abi.abi_emit_fn_prologue
        (emitter()) framesz callsz nabi_rust
        (upcall_fixup "upcall_grow_task");

      write_frame_info_ptrs (Some fnid);
      begin
        match proto_opt with
            Some proto ->
              (* FIXME: might I be a closure? if so, then Some ... *)
              abi.Abi.abi_emit_iterator_prologue (emitter()) (current_fn_args_rty None) proto
          | None -> ()
      end;
      iflog (fun _ -> annotate "finished prologue");
  in

  let trans_frame_exit (fnid:node_id) (drop_slots:bool) : unit =
    Stack.iter patch (Stack.pop epilogue_jumps);
    if drop_slots
    then
      begin
        iflog (fun _ -> annotate "drop frame");
        iter_frame_and_arg_slots fnid callee_drop_slot;
      end;
    iflog (fun _ -> annotate "epilogue");
    abi.Abi.abi_emit_fn_epilogue (emitter());
    capture_emitted_quads (get_fn_fixup cx fnid) fnid;
    pop_emitter ()
  in

  let trans_fn
      (fnid:node_id)
      (proto_opt:Ast.proto option)
      (body:Ast.block)
      : unit =
    Stack.push fnid fns;
    trans_frame_entry fnid proto_opt;
    trans_block body;
    trans_frame_exit fnid true;
    ignore (Stack.pop fns);
  in

  let trans_obj_ctor
      (obj_id:node_id)
      (state:Ast.header_slots)
      : unit =
    trans_frame_entry obj_id None;

    let slots = Array.map (fun (sloti,_) -> sloti.node) state in
    let state_ty = Ast.TY_tup slots in
    let src_rty = slot_referent_type abi (interior_slot state_ty) in
    let exterior_state_slot = exterior_slot state_ty in
    let state_ptr_rty = slot_referent_type abi exterior_state_slot in
    let state_malloc_sz =
      exterior_rc_allocation_size exterior_state_slot
    in

    let ctor_ty = Hashtbl.find cx.ctxt_all_item_types obj_id in
    let obj_ty =
      match ctor_ty with
          Ast.TY_fn (tsig, _) -> slot_ty tsig.Ast.sig_output_slot
        | _ -> bug () "object constructor doesn't have function type"
    in
    let vtbl_ptr = trans_obj_vtbl obj_id in
    let _ = iflog (fun _ -> annotate "calculate vtbl-ptr from displacement") in
    let src_cell = crate_rel_to_ptr vtbl_ptr Il.CodeTy in

    let _ = iflog (fun _ -> annotate "load destination obj pair ptr") in
    let dst_pair_cell = deref (ptr_at (fp_imm out_mem_disp) obj_ty) in
    let dst_pair_item_cell = get_element_ptr dst_pair_cell Abi.binding_field_item in
    let dst_pair_state_cell = get_element_ptr dst_pair_cell Abi.binding_field_binding in

      (* Load first cell of pair with vtbl ptr.*)
      iflog (fun _ -> annotate "mov vtbl-ptr to obj.item cell");
      mov dst_pair_item_cell (Il.Cell src_cell);

      (* Load second cell of pair with pointer to fresh state tuple.*)
      iflog (fun _ -> annotate (Printf.sprintf
                                  "malloc %Ld state-tuple bytes to obj.state cell"
                                  state_malloc_sz));
      trans_malloc dst_pair_state_cell state_malloc_sz;

      (* Copy args into the state tuple. *)
      let state_ptr = next_vreg_cell (need_scalar_ty state_ptr_rty) in
        iflog (fun _ -> annotate "load obj.state ptr to vreg");
        mov state_ptr (Il.Cell dst_pair_state_cell);
        let state = deref state_ptr in
        let refcnt_cell = get_element_ptr state 0 in
        let body_cell = get_element_ptr state 1 in
        let src_arg_mem = (fp_imm arg0_disp, src_rty) in
          iflog (fun _ -> annotate "write refcnt=1 to state[0]");
          mov refcnt_cell one;
          iflog (fun _ -> annotate "copy state args to state[1..]");
          trans_copy_tup true body_cell (Il.Mem src_arg_mem) slots;
          trans_frame_exit obj_id false;
  in

  let string_of_name_component (nc:Ast.name_component) : string =
    match nc with
        Ast.COMP_ident i -> i
      | _ -> bug ()
          "Trans.string_of_name_component on non-COMP_ident"
  in


  let trans_static_name_components (ncs:Ast.name_component list) : Il.operand =
    let f nc =
      trans_crate_rel_static_string_frag (string_of_name_component nc)
    in
      trans_crate_rel_data_operand
        (DATA_name (Walk.name_of ncs))
        (fun _ -> Asm.SEQ (Array.append
                             (Array.map f (Array.of_list ncs))
                             [| Asm.WORD (word_ty_mach, Asm.IMM 0L) |]))
  in

  let trans_required_fn (fnid:node_id) (proto_opt:Ast.proto option) (blockid:node_id) : unit =
    trans_frame_entry fnid proto_opt;
    emit (Il.Enter (Hashtbl.find cx.ctxt_block_fixups blockid));
    let (ilib, conv) = Hashtbl.find cx.ctxt_required_items fnid in
    let lib_num =
      htab_search_or_add cx.ctxt_required_lib_num ilib
        (fun _ -> Hashtbl.length cx.ctxt_required_lib_num)
    in
    let f = next_vreg_cell (Il.AddrTy (Il.CodeTy)) in
    let n_ty_params = n_item_ty_params cx fnid in
    let args_rty = direct_call_args_referent_type cx fnid in
    let caller_args_cell = caller_args_cell args_rty in
    let callee_args_cell = callee_args_cell false args_rty in
      begin
        match ilib with
            REQUIRED_LIB_rust ls ->
              begin
                let c_sym_num =
                  htab_search_or_add cx.ctxt_required_c_sym_num
                    (ilib, "rust_crate")
                    (fun _ -> Hashtbl.length cx.ctxt_required_c_sym_num)
                in
                let rust_sym_num =
                  htab_search_or_add cx.ctxt_required_rust_sym_num fnid
                    (fun _ -> Hashtbl.length cx.ctxt_required_rust_sym_num)
                in
                let path_elts = stk_elts_from_bot path in
                let _ = assert (ls.required_prefix < (List.length path_elts)) in
                let relative_path_elts = list_drop ls.required_prefix path_elts in
                let libstr = trans_static_string ls.required_libname in
                let relpath = trans_static_name_components relative_path_elts in
                  trans_upcall "upcall_require_rust_sym" f
                    [| Il.Cell (curr_crate_ptr());
                       imm (Int64.of_int lib_num);
                       imm (Int64.of_int c_sym_num);
                       imm (Int64.of_int rust_sym_num);
                       libstr;
                       relpath |];

                  let (dst_reg, _) =
                    force_to_reg (Il.Cell (alias callee_args_cell))
                  in
                  let (src_reg, _) =
                    force_to_reg (Il.Cell (alias caller_args_cell))
                  in
                  let tmp_reg = next_vreg () in
                  let nbytes =
                    force_sz (Il.referent_ty_size word_bits args_rty)
                  in
                    abi.Abi.abi_emit_inline_memcpy (emitter())
                      nbytes dst_reg src_reg tmp_reg false;
                    call_code (code_of_operand (Il.Cell f));
              end

          | REQUIRED_LIB_c ls ->
              begin
                let c_sym_str = string_of_name_component (Stack.top path) in
                let c_sym_num =
                  (* FIXME: permit remapping symbol names to handle
                   * mangled variants.
                   *)
                  htab_search_or_add cx.ctxt_required_c_sym_num (ilib, c_sym_str)
                    (fun _ -> Hashtbl.length cx.ctxt_required_c_sym_num)
                in
                let libstr = trans_static_string ls.required_libname in
                let symstr = trans_static_string c_sym_str in
                let check_rty_sz rty =
                  let sz = force_sz (Il.referent_ty_size word_bits rty) in
                    if sz = 0L || sz = word_sz
                    then ()
                    else bug () "bad arg or ret cell size for native require"
                in
                let out =
                  get_element_ptr caller_args_cell Abi.calltup_elt_out_ptr
                in
                let _ = check_rty_sz (pointee_type out) in
                let args =
                  let ty_params_cell =
                    get_element_ptr caller_args_cell Abi.calltup_elt_ty_params
                  in
                  let args_cell =
                    get_element_ptr caller_args_cell Abi.calltup_elt_args
                  in
                  let n_args =
                    match args_cell with
                        Il.Mem (_, Il.StructTy elts) -> Array.length elts
                      | _ -> bug () "non-StructTy in Trans.trans_required_fn"
                  in
                  let mk_ty_param i =
                    Il.Cell (get_element_ptr ty_params_cell i)
                  in
                  let mk_arg i =
                    let arg = get_element_ptr args_cell i in
                    let _ = check_rty_sz (Il.cell_referent_ty arg) in
                      Il.Cell arg
                  in
                    Array.append
                      (Array.init n_ty_params mk_ty_param)
                      (Array.init n_args mk_arg)
                in
                let nabi = { nabi_convention = conv;
                             nabi_indirect = true }
                in
                  if conv <> CONV_rust
                  then assert (n_ty_params = 0);
                  trans_upcall "upcall_require_c_sym" f
                    [| Il.Cell (curr_crate_ptr());
                       imm (Int64.of_int lib_num);
                       imm (Int64.of_int c_sym_num);
                       libstr;
                       symstr |];

                  abi.Abi.abi_emit_native_call_in_thunk (emitter())
                    out nabi (Il.Cell f) args;
              end

          | _ -> bug ()
              "Trans.required_rust_fn on unexpected form of require library"
      end;
      emit Il.Leave;
      trans_frame_exit fnid false;
  in

  let trans_tag
      (n:Ast.ident)
      (tagid:node_id)
      (tag:(Ast.header_tup * Ast.ty_tag * node_id))
      : unit =
    trans_frame_entry tagid None;
    trace_str cx.ctxt_sess.Session.sess_trace_tag
      ("in tag constructor " ^ n);
    let (header_tup, _, _) = tag in
    let ctor_ty = Hashtbl.find cx.ctxt_all_item_types tagid in
    let ttag =
      match ctor_ty with
          Ast.TY_fn (tsig, _) ->
            begin
              match slot_ty tsig.Ast.sig_output_slot with
                  Ast.TY_tag ttag -> ttag
                | Ast.TY_iso tiso -> get_iso_tag tiso
                | _ -> bugi cx tagid "unexpected fn type for tag constructor"
            end
        | _ -> bugi cx tagid "unexpected type for tag constructor"
    in
    let slots =
      Array.map (fun sloti -> referent_to_slot cx sloti.id) header_tup
    in
    let tag_keys = sorted_htab_keys ttag in
    let i = arr_idx tag_keys (Ast.NAME_base (Ast.BASE_ident n)) in
    let _ = log cx "tag variant: %s -> tag value #%d" n i in
    let out_cell = deref (ptr_at (fp_imm out_mem_disp) (Ast.TY_tag ttag)) in
    let tag_cell = get_element_ptr out_cell 0 in
    let union_cell = get_element_ptr out_cell 1 in
    let dst = get_variant_ptr union_cell i in
    let dst_ty = snd (need_mem_cell dst) in
    let src = Il.Mem (fp_imm arg0_disp, dst_ty) in
      (* A clever compiler will inline this. We are not clever. *)
        iflog (fun _ -> annotate (Printf.sprintf "write tag #%d" i));
        mov tag_cell (imm (Int64.of_int i));
        iflog (fun _ -> annotate ("copy tag-content tuple: dst_ty=" ^
                                    (Il.string_of_referent_ty dst_ty)));
        trans_copy_tup true dst src slots;
        trace_str cx.ctxt_sess.Session.sess_trace_tag
          ("finished tag constructor " ^ n);
        trans_frame_exit tagid true;
  in

  let enter_file_for id =
    if Hashtbl.mem cx.ctxt_item_files id
    then Stack.push id curr_file
  in

  let leave_file_for id =
    if Hashtbl.mem cx.ctxt_item_files id
    then
      if Stack.is_empty curr_file
      then bugi cx id "Missing source file on file-scope exit."
      else ignore (Stack.pop curr_file)
  in

  let visit_local_mod_item_pre n _ i =
    iflog (fun _ -> log cx "translating local item #%d = %s" (int_of_node i.id) (path_name()));
    match i.node.Ast.decl_item with
        Ast.MOD_ITEM_fn f ->
          if path_name() = cx.ctxt_main_name
          then
            begin
              log cx "emitting main exit-task glue for %s" cx.ctxt_main_name;
              emit_exit_task_glue
                cx.ctxt_main_exit_task_glue_fixup
                GLUE_exit_main_task;
            end;
          trans_fn i.id f.Ast.fn_aux.Ast.fn_proto f.Ast.fn_body

      | Ast.MOD_ITEM_pred p -> trans_fn i.id None p.Ast.pred_body
      | Ast.MOD_ITEM_tag t -> trans_tag n i.id t
      | Ast.MOD_ITEM_obj ob -> trans_obj_ctor i.id ob.Ast.obj_state
      | _ -> ()
  in

  let visit_required_mod_item_pre _ _ i =
    iflog (fun _ -> log cx "translating required item #%d = %s" (int_of_node i.id) (path_name()));
    match i.node.Ast.decl_item with
        Ast.MOD_ITEM_fn f -> trans_required_fn i.id f.Ast.fn_aux.Ast.fn_proto f.Ast.fn_body.id
      | Ast.MOD_ITEM_mod _ -> ()
      | Ast.MOD_ITEM_type _ -> ()
      | _ -> bugi cx i.id "unsupported type of require: %s" (path_name())
  in

  let visit_local_obj_fn_pre _ _ fn =
    trans_fn fn.id fn.node.Ast.fn_aux.Ast.fn_proto fn.node.Ast.fn_body
  in

  let visit_required_obj_fn_pre _ _ _ =
    ()
  in

  let visit_obj_fn_pre obj ident fn =
    enter_file_for fn.id;
    begin
      if Hashtbl.mem cx.ctxt_required_items fn.id
      then
        visit_required_obj_fn_pre obj ident fn
      else
        visit_local_obj_fn_pre obj ident fn
    end;
    inner.Walk.visit_obj_fn_pre obj ident fn
  in

  let visit_mod_item_pre n p i =
    enter_file_for i.id;
    begin
      if Hashtbl.mem cx.ctxt_required_items i.id
      then
        visit_required_mod_item_pre n p i
      else
        visit_local_mod_item_pre n p i
    end;
    inner.Walk.visit_mod_item_pre n p i
  in

  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    leave_file_for i.id
  in

  let visit_obj_fn_post obj ident fn =
    inner.Walk.visit_obj_fn_post obj ident fn;
    leave_file_for fn.id
  in

  let visit_crate_pre crate =
    enter_file_for crate.id;
    inner.Walk.visit_crate_pre crate
  in

  let visit_crate_post crate =

    inner.Walk.visit_crate_post crate;

    let emit_aux_global_glue cx glue fix fn =
      let glue_name = glue_str cx glue in
      push_new_emitter_without_vregs ();
      let e = emitter() in
        fn e;
        iflog (fun _ -> annotate_quads glue_name);
        if (Il.num_vregs e) != 0
        then bug () "%s uses nonzero vregs" glue_name;
        pop_emitter();
        let code =
          { code_fixup = fix;
            code_quads = emitted_quads e;
            code_vregs_and_spill = None;
            code_spill_disp = 0L }
        in
          htab_put cx.ctxt_glue_code glue code
    in

    let tab_sz htab =
      Asm.WORD (word_ty_mach, Asm.IMM (Int64.of_int (Hashtbl.length htab)))
    in

    let crate_data =
      (cx.ctxt_crate_fixup,
       Asm.DEF
         (cx.ctxt_crate_fixup,
          Asm.SEQ [|
            (* 
             * NB: this must match the rust_crate structure
             * in the rust runtime library.
             *)
            crate_rel_word cx.ctxt_image_base_fixup;
            Asm.WORD (word_ty_mach, Asm.M_POS cx.ctxt_crate_fixup);

            crate_rel_word cx.ctxt_debug_abbrev_fixup;
            Asm.WORD (word_ty_mach, Asm.M_SZ cx.ctxt_debug_abbrev_fixup);

            crate_rel_word cx.ctxt_debug_info_fixup;
            Asm.WORD (word_ty_mach, Asm.M_SZ cx.ctxt_debug_info_fixup);

            crate_rel_word cx.ctxt_activate_fixup;
            crate_rel_word cx.ctxt_main_exit_task_glue_fixup;
            crate_rel_word cx.ctxt_unwind_fixup;
            crate_rel_word cx.ctxt_yield_fixup;

            tab_sz cx.ctxt_required_rust_sym_num;
            tab_sz cx.ctxt_required_c_sym_num;
            tab_sz cx.ctxt_required_lib_num;
          |]))
    in

      (* Emit additional glue we didn't do elsewhere. *)
      emit_aux_global_glue cx GLUE_activate
        cx.ctxt_activate_fixup
        abi.Abi.abi_activate;

      emit_aux_global_glue cx GLUE_yield
        cx.ctxt_yield_fixup
        abi.Abi.abi_yield;

      emit_aux_global_glue cx GLUE_unwind
        cx.ctxt_unwind_fixup
        (fun e -> abi.Abi.abi_unwind
           e nabi_rust (upcall_fixup "upcall_exit"));

      begin
        match abi.Abi.abi_get_next_pc_thunk with
            None -> ()
          | Some (_, fix, fn) ->
              emit_aux_global_glue cx GLUE_get_next_pc fix fn
      end;

      htab_put cx.ctxt_data
        DATA_crate crate_data;

      provide_existing_native cx SEG_data "rust_crate" cx.ctxt_crate_fixup;

      leave_file_for crate.id
  in

    { inner with
        Walk.visit_crate_pre = visit_crate_pre;
        Walk.visit_crate_post = visit_crate_post;
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
        Walk.visit_obj_fn_pre = visit_obj_fn_pre;
        Walk.visit_obj_fn_post = visit_obj_fn_post;
    }
;;


let fixup_assigning_visitor
    (cx:ctxt)
    (path:Ast.name_component Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =

  let path_name (_:unit) : string =
    Ast.fmt_to_str Ast.fmt_name (Walk.path_to_name path)
  in

  let enter_file_for id =
    if Hashtbl.mem cx.ctxt_item_files id
    then
      begin
        let name =
          if Stack.is_empty path
          then "crate root"
          else path_name()
        in
        htab_put cx.ctxt_file_fixups id (new_fixup name);
        if not (Hashtbl.mem cx.ctxt_file_code id)
        then htab_put cx.ctxt_file_code id (Hashtbl.create 0);
      end
  in

  let visit_mod_item_pre n p i =
    enter_file_for i.id;
    begin
      match i.node.Ast.decl_item with

          Ast.MOD_ITEM_pred _
        | Ast.MOD_ITEM_tag _ ->
            htab_put cx.ctxt_fn_fixups i.id
              (new_fixup (path_name()));

        | Ast.MOD_ITEM_fn _ ->
            begin
              let path = path_name () in
              let fixup =
                if path = cx.ctxt_main_name
                then cx.ctxt_main_fn_fixup
                else new_fixup path
              in
                htab_put cx.ctxt_fn_fixups i.id fixup;
            end

        | Ast.MOD_ITEM_obj _ ->
            htab_put cx.ctxt_fn_fixups i.id
              (new_fixup (path_name()));

        | _ -> ()
    end;
    inner.Walk.visit_mod_item_pre n p i
  in

  let visit_obj_fn_pre obj ident fn =
    htab_put cx.ctxt_fn_fixups fn.id
      (new_fixup (path_name()));
    inner.Walk.visit_obj_fn_pre obj ident fn
  in

  let visit_block_pre b =
    htab_put cx.ctxt_block_fixups b.id (new_fixup "lexical block");
    inner.Walk.visit_block_pre b
  in

  let visit_crate_pre c =
    enter_file_for c.id;
    inner.Walk.visit_crate_pre c
  in

  { inner with
      Walk.visit_crate_pre = visit_crate_pre;
      Walk.visit_mod_item_pre = visit_mod_item_pre;
      Walk.visit_obj_fn_pre = visit_obj_fn_pre;
      Walk.visit_block_pre = visit_block_pre; }


let process_crate
    (cx:ctxt)
    (crate:Ast.crate)
    : unit =
  let path = Stack.create () in
  let passes =
    [|
      (fixup_assigning_visitor cx path
         Walk.empty_visitor);
      (trans_visitor cx path
         Walk.empty_visitor)
    |];
  in
    log cx "translating crate with main function %s" cx.ctxt_main_name;
    run_passes cx "trans" path passes (log cx "%s") crate;
;;

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
