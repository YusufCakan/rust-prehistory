#ifndef LOCK_FREE_QUEUE_H_
#define LOCK_FREE_QUEUE_H_

class lock_free_queue_node {
	lock_free_queue_node *next;
};

class lock_free_queue {
public:
	lock_free_queue();
	void enqueue(lock_free_queue_node *item);
	lock_free_queue_node *dequeue();
};

#endif /* LOCK_FREE_QUEUE_H_ */
