contract UintQueue {
	uint[] array0;
	uint[] array1;
	uint8 queueArray;
	uint8 dequeueArray;
	uint dequeueIndex;
	uint public length;
	
	function UintQueue() {
        dequeueArray = 1;
	}
	
	function queue(uint val) {
		uint[] array = getQueueArray();
		array[array.length++] = val;
		length++;
	}

	function peek() returns (uint val) {
		if (length == 0) {
			uint thrownow = array0[array0.length]; //throw exception the sneaky way
			return 0;
		}
		uint[] array = getDequeueArray();
        if (dequeueIndex == array.length) {
            uint[] other = getQueueArray();
            val = other[0];
        }
        else {
            val = array[dequeueIndex];
        }
	}

	function dequeue() returns (uint result) {
		result = peek();
		length--;
		
        uint[] dequeue = getDequeueArray();
		if (dequeueIndex == dequeue.length) {
			delete dequeue;
			queueArray ^= 1; //flip the bit
			dequeueArray ^= 1;
			dequeueIndex = 1; //set for the *next* dequeue
		}
        else {
            dequeueIndex++;
        }
	}
	
	function getQueueArray() private returns (uint[] array) {
		if (queueArray == 0) {
			array = array0;
		}
		else {
			array = array1;
		}
	}
	
	function getDequeueArray() private returns (uint[] array) {
		if (dequeueArray == 0) {
			array = array0;
		}
		else {
			array = array1;
		}
	}
}
