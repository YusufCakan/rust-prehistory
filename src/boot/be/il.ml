open Common;;

(* Operands. *)

type name = Base of string
            | Ext of name * string
;;

type vreg = int ;;
type hreg = int ;;
type label = int ;;
type spill = int ;;

type reg =
    Vreg of vreg
  | Hreg of hreg
;;

type bits =
    Bits8 
  | Bits16
  | Bits32
  | Bits64
;;

type regbits =
    {
      reg_val: reg;
      reg_bits: bits
    }
;;

type immbits =
    {
      imm_val: Asm.expr64;
      imm_bits: bits
    }
;;

type addr =
    Abs of Asm.expr64
  | Deref of reg
  | Idx of (reg * Asm.expr64)
;;

type 'targ ptr =
    {
      ptr_addr: addr;
      ptr_targ: 'targ
    } 
;;

type code =
    CodeLabel of label (* Index into current quad block. *)
  | CodeAddr of addr
;;

type cell = 
    Reg of regbits
  | Spill of spill
;;

type scalar =
    Cell of cell
  | Imm of immbits
;;

type referent =
    Record of (name * layout) array
  | Opaque
;;

type pointer = referent ptr
;;

type operand =
    Scalar of (name * scalar)
  | Pointer of (name * pointer)
;;

(* NB: for the most part, we let the register allocator assign spills
 * from vregs, and we permanently allocate aliased slots to stack
 * locations by static aliasing information early, in layout.
 * 
 * The one awkward case this doesn't handle is when someone tries to
 * pass a literal-atom to an alias-slot. This *requires* a memory slot
 * but we only realize it rather late, much later than we'd normally
 * have thougt to desugar the literal into a temporary.
 * 
 * So in these cases, we let the trans module explicitly demand a
 * "Spill n" operand, which the register allocator mops up before it
 * gets started on the vregs.
 * 
 * NOTE: if we were more clever we'd integrate vregs and spills like
 * this together along with the general notion of a temporary way back
 * at the desugaring stage, and use some kind of size-class
 * consolidation so that spills with non-overlapping lifetimes could
 * share memory. But we're not that clever yet.
 *)


(* Quads. *)

type binop = 
    ADD | SUB
  | IMUL | UMUL
  | IDIV | UDIV
  | IMOD | UMOD
  | AND | OR
  | LSL | LSR | ASR
;;

type unop =
    NEG | NOT
  | UMOV | IMOV
  | LEA
;;    

type jmpop = 
    JE | JNE
  | JL | JLE | JG | JGE (* Signed.   *)
  | JB | JBE | JA | JAE (* Unsigned. *)
  | JC | JNC | JO | JNO
  | JMP
  | CALL
;;

type binary =
    {
      binary_op: binop;
      binary_dst: (name * cell);
      binary_lhs: operand;
      binary_rhs: operand }
;;

type unary = { unary_op: unop;
               unary_dst: (name * cell);
               unary_src: operand }
;;

type cmp = { cmp_lhs: operand;
             cmp_rhs: operand }
;;


type jmp = { jmp_op: jmpop; 
             jmp_targ: (name * code); }
;;

type quad' =
    Binary of binary
  | Unary of unary
  | Cmp of cmp
  | Jmp of jmp
  | Push of operand
  | Pop of operand
  | Ret  (* Return to caller. *)
  | Nop  (* Keep this quad here, emit CPU nop, will patch / trampoline later. *)
  | Dead (* Keep this quad but emit nothing. *)
  | End  (* Space past the end of quads to emit. *)
;;

type quad =
    { quad_fixup: fixup option;
      quad_body: quad'; }

type quads = quad array ;;

(* Formatters. *)

type hreg_formatter = hreg -> string;;

let string_of_reg (f:hreg_formatter) (r:reg) : string =
  match r with
      Vreg i -> Printf.sprintf "<v %d>" i
    | Hreg i -> f i
;;

let rec string_of_expr64 (e64:Asm.expr64) : string =
  let bin op a b =
    Printf.sprintf "(%s %s %s)" (string_of_expr64 a) op (string_of_expr64 b)
  in
  let bini op a b =
    Printf.sprintf "(%s %s %d)" (string_of_expr64 a) op b
  in
    match e64 with
        Asm.IMM i -> Printf.sprintf "0x%Lx" i
      | Asm.ADD (a,b) -> bin "+" a b
      | Asm.SUB (a,b) -> bin "-" a b
      | Asm.MUL (a,b) -> bin "*" a b
      | Asm.DIV (a,b) -> bin "/" a b
      | Asm.REM (a,b) -> bin "%" a b
      | Asm.SLL (a,b) -> bini "<<" a b
      | Asm.SLR (a,b) -> bini ">>" a b
      | Asm.SAR (a,b) -> bini ">>>" a b
      | Asm.AND (a,b) -> bin "&" a b
      | Asm.XOR (a,b) -> bin "xor" a b
      | Asm.OR (a,b) -> bin "|" a b
      | Asm.NOT a -> Printf.sprintf "(not %s)" (string_of_expr64 a)
      | Asm.F_POS f -> Printf.sprintf "%s.fpos" f.fixup_name
      | Asm.F_SZ f -> Printf.sprintf "%s.fsz" f.fixup_name
      | Asm.M_POS f -> Printf.sprintf "%s.mpos" f.fixup_name
      | Asm.M_SZ f -> Printf.sprintf "%s.msz" f.fixup_name
      | Asm.EXT e -> "??ext??"
;;

let string_of_addr (f:hreg_formatter) (a:addr) : string =
  match a with
      Deref r -> "[" ^ (string_of_reg f r) ^ "]"
    | Abs e -> "[" ^ (string_of_expr64 e) ^ "]"
    | Idx (r,e) -> ("[" ^  (string_of_reg f r) ^ 
                      " + " ^ (string_of_expr64 e) ^ "]")
;;

let string_of_code (f:hreg_formatter) (c:code) : string =
  match c with
      CodeLabel lab -> Printf.sprintf "<label %d>" lab
    | CodeAddr a -> string_of_addr f a
;;

let string_of_cell (f:hreg_formatter) (c:cell) : string =
  match c with
      Reg r -> string_of_reg f r.reg_val
    | Spill i -> Printf.sprintf "<spill %d>" i
;;

let string_of_scalar (f:hreg_formatter) (s:scalar) : string =
  match s with
      Cell c -> string_of_cell f c
    | Imm i -> string_of_expr64 i.imm_val
;;  

let string_of_ptr (f:hreg_formatter) (p:'targ ptr) : string =
  string_of_addr f p.ptr_addr
;;

let string_of_operand (f:hreg_formatter) (op:operand) : string =
  match op with
      Scalar (_,s) -> string_of_scalar f s
    | Pointer (_,p) -> string_of_ptr f p
;;

let string_of_binop (op:binop) : string =
  match op with
      ADD -> "add"
    | SUB -> "sub"
    | IMUL -> "imul"
    | UMUL -> "umul"
    | IDIV -> "idiv"
    | UDIV -> "udiv"
    | IMOD -> "imod"
    | UMOD -> "umod"
    | AND -> "and"
    | OR -> "or"
    | LSL -> "lsl"
    | LSR -> "lsr"
    | ASR -> "asr"
;;

let string_of_unop (op:unop) : string =
  match op with
      NEG -> "neg"
    | NOT -> "not"
    | UMOV -> "umov"
    | IMOV -> "imov"
    | LEA -> "lea"
;;

let string_of_jmpop (op:jmpop) : string =
  match op with
      JE -> "je"
    | JNE -> "jne"
    | JL -> "jl"
    | JLE -> "jle"
    | JG -> "jg"
    | JGE -> "jge"
    | JB -> "jb"
    | JBE -> "jbe"
    | JA -> "ja"
    | JAE -> "jae"
    | JC -> "jc"
    | JNC ->"jnc"
    | JO -> "jo"
    | JNO -> "jno"
    | JMP -> "jmp"
    | CALL -> "call"
;;

let string_of_quad (f:hreg_formatter) (q:quad) : string =
  match q.quad_body with
      Binary b -> 
        Printf.sprintf "%s = %s %s %s"
          (string_of_cell f (snd b.binary_dst))
          (string_of_operand f b.binary_lhs)
          (string_of_binop b.binary_op)
          (string_of_operand f b.binary_rhs)

    | Unary u ->
        Printf.sprintf "%s = %s %s"
          (string_of_cell f (snd u.unary_dst))
          (string_of_unop u.unary_op)
          (string_of_operand f u.unary_src)

    | Cmp c ->
        Printf.sprintf "cmp %s %s"
          (string_of_operand f c.cmp_lhs)
          (string_of_operand f c.cmp_rhs)
        
    | Jmp j ->
        Printf.sprintf "%s %s"
          (string_of_jmpop j.jmp_op)
          (string_of_code f (snd j.jmp_targ))
        
    | Push op ->
        Printf.sprintf "push %s"
          (string_of_operand f op)

    | Pop op ->
        Printf.sprintf "%s = pop"
          (string_of_operand f op)
        
    | Ret -> "ret"
    | Nop -> "nop"
    | Dead -> "dead"
    | End -> "---"
;;




(************************************)
(*           OLD CODE               *)
(************************************)

(* 
type vreg = int
;;

type hreg = int
;;

type reg = Vreg of vreg
           | Hreg of hreg
;;

type mem = M8 | M16 | M32 | M64
;;

type operand =  Label of int
                | Imm of Asm.expr64
                | Pcrel of fixup
                | Reg of reg
                | Spill of int
                | Mem of (mem * (reg option) * Asm.expr64)
                | Nil
;;

let is_mem op =
  match op with
      Mem _ | Spill _ | Pcrel _ -> true
    | _ -> false
;;


type op =
    ADD | SUB | NEG
  | IMUL | UMUL
  | IDIV | UDIV
  | IMOD | UMOD
  | IMOV | UMOV
  | CMP
  | LEA
  | AND | OR | NOT
  | LSL | LSR | ASR
  | JE | JNE | JL | JLE | JG | JGE (* Signed.   *)
             | JB | JBE | JA | JAE (* Unsigned. *)
  | JC | JNC | JO | JNO | JMP
  | CALL | RET | YIELD | RESUME
  | CCALL | CPUSH of mem | CPOP of mem | CRET
  | NOP | DEAD | END
;;


type quad = { quad_op: op;
              quad_dst: operand;
              quad_lhs: operand;
              quad_rhs: operand;
              quad_fixup: fixup option;
            }
;;


type quads = quad array
;;

let is_primitive_reg r =
  match r with
      Hreg _ -> true
    | _ -> false
;;


let is_primitive_operand op =
  match op with
      Label _ -> false
    | Reg r -> is_primitive_reg r
    | Mem (_, Some r, _) -> is_primitive_reg r
    | _ -> true
;;


let is_primitive_quad q =
  (is_primitive_operand q.quad_dst)
  && (is_primitive_operand q.quad_lhs)
  && (is_primitive_operand q.quad_rhs)
;;

let string_of_operand (f:int->string) operand =
  match operand with
      Reg r -> string_of_reg f r
    | Imm (Asm.IMM i) -> Printf.sprintf "0x%Lx" i
    | Imm e -> Printf.sprintf "<imm %s>" (string_of_expr64 e)
    | Pcrel f -> "<" ^ f.fixup_name ^ ">"
    | Mem (_, (Some r),e) -> Printf.sprintf "%s[%s]" (string_of_reg f r) (string_of_expr64 e)
    | Mem (_, None,e) -> Printf.sprintf "*(%s)" (string_of_expr64 e)
    | Label i -> "<lab" ^ (string_of_int i) ^ ">"
    | Nil -> "nil"
    | Spill i -> Printf.sprintf "<spill %d>" i
;;

let string_of_mem m =
  match m with
      M8 -> "M8"
    | M16 -> "M16"
    | M32 -> "M32"
    | M64 -> "M64"
;;

let string_of_op op =
  match op with
      ADD -> "ADD"
    | SUB -> "SUB"
    | NEG -> "NEG"
    | UMUL -> "UMUL"
    | IMUL -> "IMUL"
    | UDIV -> "UDIV"
    | IDIV -> "IDIV"
    | UMOD -> "UMOD"
    | IMOD -> "IMOD"
    | UMOV -> "UMOV"
    | IMOV -> "IMOV"
    | LEA -> "LEA"
    | CMP -> "CMP"
    | AND -> "AND"
    | OR -> "OR"
    | NOT -> "NOT"
    | LSL -> "LSL"
    | LSR -> "LSR"
    | ASR -> "ASR"
    | JC -> "JC"
    | JNC ->"JNC"
    | JO -> "JO"
    | JNO -> "JNO"
    | JE -> "JE"
    | JNE -> "JNE"
    | JL -> "JL"
    | JLE -> "JLE"
    | JG -> "JG"
    | JGE -> "JGE"
    | JB -> "JB"
    | JBE -> "JBE"
    | JA -> "JA"
    | JAE -> "JAE"
    | JMP -> "JMP"
    | CALL -> "CALL"
    | RET -> "RET"
    | NOP -> "NOP"
    | DEAD -> "DEAD"
    | CCALL -> "CCALL"
    | CPUSH m -> "CPUSH:" ^ string_of_mem m
    | CPOP m -> "CPOP:" ^ string_of_mem m
    | CRET -> "CRET"
    | RESUME -> "RESUME"
    | YIELD -> "YIELD"
    | END -> "---"
;;


let string_of_quad f t =
  match t.quad_op with
      ADD | SUB | IMUL | UMUL | IDIV | UDIV | IMOD | UMOD
    | AND | OR | LSL | LSR | ASR ->
        Printf.sprintf "%s = %s %s %s"
          (string_of_operand f t.quad_dst)
          (string_of_operand f t.quad_lhs)
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_rhs)

    | NOT | NEG ->
        Printf.sprintf "%s = %s %s"
          (string_of_operand f t.quad_dst)
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_lhs)

    | IMOV | UMOV ->
        Printf.sprintf "%s = %s"
          (string_of_operand f t.quad_dst)
          (string_of_operand f t.quad_lhs)

    | LEA ->
        Printf.sprintf "%s = %s(%s)"
          (string_of_operand f t.quad_dst)
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_lhs)

    | CMP ->
        Printf.sprintf "%s %s %s"
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_lhs)
          (string_of_operand f t.quad_rhs)

    | JMP | JE | JNE | JL | JLE | JG | JGE
    | JB | JBE | JA | JAE | JC | JNC | JO | JNO
    | CALL | RESUME | CCALL | CPUSH _  ->
        Printf.sprintf "%s %s"
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_lhs)

    | CPOP _ ->
        Printf.sprintf "%s %s"
          (string_of_op t.quad_op)
          (string_of_operand f t.quad_dst)

    | RET | YIELD | CRET | NOP | DEAD | END ->
        (string_of_op t.quad_op)
;;

*)


type emitter = { mutable emit_pc: int;
                 mutable emit_next_vreg: int;
                 mutable emit_next_spill: int;
                 emit_preallocator: (quad -> quad);
                 emit_is_2addr: bool;
                 mutable emit_quads: quads; }


let badq = { quad_fixup = None;
             quad_body = End }
;;


let deadq = { quad_fixup = None;
              quad_body = Dead }
;;


let new_emitter (preallocator:quad -> quad) (is_2addr:bool) =
  {
    emit_pc = 0;
    emit_next_vreg = 0;
    emit_next_spill = 0;
    emit_preallocator = preallocator;
    emit_is_2addr = is_2addr;
    emit_quads = Array.create 4 badq;
  }
;;


let next_vreg_num e =
  let i = e.emit_next_vreg in
    e.emit_next_vreg <- i + 1;
    i
;;

let next_vreg e =
  let i = e.emit_next_vreg in
    e.emit_next_vreg <- i + 1;
    (Vreg i)
;;

let next_spill e =
  let i = e.emit_next_spill in
    e.emit_next_spill <- i + 1;
    (Spill i)
;;


let grow_if_necessary e =
  let len = Array.length e.emit_quads in
    if e.emit_pc >= len - 1
    then
      let n = Array.create (2 * len) badq in
        Array.blit e.emit_quads 0 n 0 len;
        e.emit_quads <- n
;;



(* 
let emit_full e fix op dst lhs rhs =
  let fixup = ref fix in
  let emit_quad_bottom q =
    grow_if_necessary e;
    e.emit_quads.(e.emit_pc) <- { q with quad_fixup = (!fixup) };
    fixup := None;
    e.emit_pc <- e.emit_pc + 1
  in

  let mq op d l r = { quad_op = op; quad_dst = d;
                      quad_lhs = l; quad_rhs = r; quad_fixup = None }
  in

  let is_mov q = q.quad_op = UMOV or q.quad_op = IMOV in
  let emit_quad q =
    (* decay mem-mem movs *)
    if ((is_mov q) &&
          (is_mem q.quad_dst) &&
          (is_mem q.quad_lhs))
    then
      begin
        let dst = q.quad_dst in
        let src = q.quad_lhs in
        let v = (Reg (next_vreg e)) in
          emit_quad_bottom (mq q.quad_op v src Nil);
          emit_quad_bottom (mq q.quad_op dst v Nil)
      end
    else
      emit_quad_bottom q
  in

  let default_mov =
    match op with
        IMOV | IDIV | IMUL | IMOD -> IMOV
      | _ -> UMOV
  in

  let emit_mov dst src =
    emit_quad (mq default_mov dst src Nil)
  in

  let quad = (mq op dst lhs rhs) in
  let quad' = e.emit_preallocator quad in
    if quad'.quad_lhs != quad.quad_lhs
    then emit_mov quad'.quad_lhs quad.quad_lhs
    else ();
    if quad'.quad_rhs != quad.quad_rhs
    then emit_mov quad'.quad_rhs quad.quad_rhs
    else ();
    if e.emit_is_2addr
      && (quad'.quad_lhs != quad'.quad_dst)
      && (quad'.quad_dst != Nil)
      && (quad'.quad_lhs != Nil)
      && (quad'.quad_rhs != Nil)
    then
      begin
        emit_mov quad'.quad_dst quad'.quad_lhs;
        emit_quad { quad' with quad_lhs = quad'.quad_dst }
      end
    else
      emit_quad quad';
    if (quad'.quad_dst != quad.quad_dst)
      && (quad'.quad_dst != Nil)
      && (quad.quad_dst != Nil)
    then emit_mov quad.quad_dst quad'.quad_dst
    else ();
;;

let emit e op dst lhs rhs =
  emit_full e None op dst lhs rhs
;;

let badlab = Label (-1);;

let patch_jump (e:emitter) (jmp:int) (targ:int) : unit =
  e.emit_quads.(jmp)
  <- { e.emit_quads.(jmp)
       with quad_lhs = Label targ }
;;
*)

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
