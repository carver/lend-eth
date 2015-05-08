/*
This contract facilitates unsecured loans of arbitrary duration and yield.
It lists outstanding requests for borrowing. When lending out cash, this
contract also tracks the interest due, and facilitates collection of
deposited funds.

Interest does not compound, but is collectable by the lender every hour, as
long as the borrower has funds deposited.

Note some key properties of these loans:
 * the coupon/interest payments are due hourly, enabling very short loans
 * loans can be offered in any length desired (in one hour blocks)
 * the contract ensures automatic payment of loans with payment due before paying down principle early
 * early payment is allowed without penalty (except within an hour, when at least one hour of interest is charged)

TODO: track repayment to compile credit history
TODO: charge optional fee to judge credit and seriousness of new asks
TODO: compound the interest by adding due interest to principle if the coupon is unpayable due to insufficient funds
private:
TODO: sweep abandoned accounts after 2 years, keep track of amounts for future claims
TODO: make collectTime() private
TODO: make payDownLoanTime() private
*/
contract BondMarket {
	//An outstanding request for a loan
	struct Ask {
		uint amount;
		uint hourlyReturn; //every hour, this much new wei is due back per ether borrowed
		address asker;
		uint duration; //duration in hours
	}
	mapping (uint => Ask) public asks;
	uint public numAsks;
	
	struct Loan {
		Ask ask;
		address lender;
		uint principle;
		uint startTime; //principle will be due at time: startTime + 3600 * ask.duration
		uint hoursCollected; //how many hours of interest have been collected
	}
	mapping (uint => Loan) loans;
	uint numLoans;
	
	//deposited funds, in ether
	mapping (address => uint) balances;
	
	//An ordered list, designed to reclaim garbage space after it drops below 50% filled
	struct Queue {
		uint start;
		uint[] vals;
	}
	mapping (address => Queue) outstandingLoans; //by borrower, ordered by first to borrow
	
	function BondMarket() {
		//loan and ask id's of 0 are used to convey an empty result, so start on id 1
		numAsks = 1;
		numLoans = 1;
	}
	
	//@Note Create a new request for funds of `amount` wei, due in `numHours`, paying back `hourlyReturn` wei per hour per ether borrowed
	function newAsk(uint amount, uint hourlyReturn, uint numHours) returns (uint) {
		Ask ask = asks[numAsks++];
		ask.amount = amount;
		ask.hourlyReturn = hourlyReturn;
		ask.asker = msg.sender;
		ask.duration = numHours;
		return numAsks-1;
	}
	
	//@Note Lend `amount` ether to loan request id `askId`, and return the id of the loan created or 0 on fail
	function sendLoan(uint askId, uint amount) returns (uint loanId) {
		//Note that this may use already deposited funds, or include a deposit of new funds
		deposit();
		forceCollection(msg.sender); //you can't loan out to others when you have outstanding payments due

		Ask ask = asks[askId];
		if (ask.amount < amount) {
			amount = ask.amount;
		}
		uint newAskSize = ask.amount - amount;
		if (ask.amount > 0 && newAskSize >= 0 && balances[msg.sender] >= amount) {
			Loan loan = loans[numLoans++];
			loan.startTime = now;
			loan.lender = msg.sender;
			loan.ask = ask;
			loan.principle = amount;
			
			ask.amount = newAskSize;
			transfer(msg.sender, loan.ask.asker, amount);
			
			if (newAskSize == 0) {
				delete asks[askId];
			}
			loanId = numLoans-1;
			uint[] askerLoans = outstandingLoans[loan.ask.asker].vals;
			askerLoans[askerLoans.length++] = loanId;
			return loanId;
		}
		return 0;
	}
	
	//@Note collect the interest and principle due on loan id `loanId`, returning amount collected in wei
	function collect(uint loanId) returns (uint) {
		return collectTime(loanId, now);
	}

	//collection run at a specified time, useful for testing. users must call collect(loanId) instead
	function collectTime(uint loanId, uint attime) returns (uint) {
		Loan loan = loans[loanId];
		
		//collect interest
		uint collectibleHours = (attime - loan.startTime) / 3600;
		uint amountDue = 0;
		if (attime > loan.startTime && collectibleHours > loan.hoursCollected) {
			uint hoursDue = collectibleHours - loan.hoursCollected;
			amountDue = hoursDue * loan.principle * loan.ask.hourlyReturn / 1 ether; //TODO: check for numerator overflows
			if (amountDue <= balances[loan.ask.asker]) {
				transfer(loan.ask.asker, loan.lender, amountDue);
				loan.hoursCollected += hoursDue;
			}
		}
		
		//collect principle
		uint dueTime = loan.startTime + loan.ask.duration * 3600;
		if (attime >= dueTime) {
			amountDue += payPrinciple(loanId);
		}
		return amountDue;
	}
	
	//@Note pay back money you borrowed in loan id `loanId`, even if the principle is not yet due
	function payDownLoan(uint loanId) {
		payDownLoanTime(loanId, now);
	}
	
	//payDownLoan run at a specific time, useful for testing. users must call payDownLoan(loanId)
	function payDownLoanTime(uint loanId, uint attime) returns (uint paid) {
		Loan loan = loans[loanId];
		if (msg.sender != loan.ask.asker) {
			return ;
		}
		deposit(); //this prepay action may include funds to execute
		
		//force interest collection on this loan
		paid = collectTime(loanId, attime);
		
		if (loan.startTime + 3600 > attime) {
			//if paying down within the first hour, must pay at least 1 hour's interest
			paid += collectTime(loanId, loan.startTime + 3601);
		}

		paid += payPrinciple(loanId);
	}
	
	//trigger principle payment, which assumes it's okay to withdraw from borrower's balance, perhaps
	//	due to borrower opt-in or the due date has passed
	function payPrinciple(uint loanId) private returns (uint amount) {
		Loan loan = loans[loanId];
		//don't prepay before outstanding debts are covered
		forceCollection(loan.ask.asker);
		amount = loan.principle;
		if (amount > balances[loan.ask.asker]) {
			amount = balances[loan.ask.asker];
		}
		transfer(loan.ask.asker, loan.lender, amount);
		loan.principle -= amount;
	}
	
	//@Note for all loans that `fromUser` has received, send interest and principle to lender as appropriate
	function forceCollection(address fromUser) {
		Queue loanQueue = outstandingLoans[fromUser];
		uint loanCount = loanQueue.vals.length;
		for (uint i = loanQueue.start; i < loanCount; i++) {
			uint loanId = loanQueue.vals[i];
			Loan loan = loans[loanId];
			if (loan.principle == 0) {
				loanQueue.start++;
				if (loanQueue.start * 2 > loanQueue.vals.length) {
					repackOutstandingLoans(fromUser);
					forceCollection(fromUser);
					return;
				}
			}
			collect(loanId);
		}
	}

	//after paying back loans, they don't need to be in the outstandingLoans array anymore,
	//	resize the array to avoid a memory leak
	function repackOutstandingLoans(address user) private {
		Queue queue = outstandingLoans[user];
		uint[] vals = queue.vals;
		uint readIndex = queue.start;
		uint newSize = queue.vals.length - readIndex;
		for (uint i = 0; i < newSize; i++) {
			vals[i] = vals[readIndex + i];
		}
		vals.length = newSize;
	}
	
	//@Note retrieve your own balance held with this contract
	function balance() returns (uint) {
		return balances[msg.sender];
	}

	//@Note deposit ether to fund a loan or repay one
	function deposit() {
		if(msg.value > 0) {
			balances[msg.sender] += msg.value;
			forceCollection(msg.sender);
		}
	}
	//@Note withdraw ether from contract, after paying all due payments
	function widthraw(uint amt) {
		forceCollection(msg.sender);
		if (balances[msg.sender] >= amt) {
			balances[msg.sender] -= amt;
			msg.sender.send(amt);
		}
	}
	function transfer(address from, address to, uint amt) private {
		if (balances[from] >= amt) {
			balances[from] -= amt;
			balances[to] += amt;
		}
	}

	//TODO: remove from final contract, but currently useful during testing
	function time() returns (uint) {
		return now;
	}
}
