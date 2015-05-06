contract BondMarket {
	struct Ask {
		uint amount;
		uint hourlyReturn; //every hour, this much new wei is due back per ether borrowed
		address asker;
		uint duration; //duration in hours
	}
	mapping (uint => Ask) public asks;
	uint numAsks;
	
	struct Loan {
		Ask ask;
		address lender;
		uint principle;
		uint startTime;
		uint hoursCollected;
	}
	mapping (uint => Loan) loans;
	uint numLoans;
	
	mapping (address => uint) balances;
	
	//TODO - on deposit or transfer, force collection of unpaid loans
	//some reward for effort?
	//TODO - sweep abandoned accounts after 2 years, keep track of amounts for future claims
	//TODO - charge (optional?) fee to screen for spam (allow the ask to post, but mark as spam)
	
	function BondMarket() {
		//let 0 be a special case, so start on id 1
		numAsks = 1;
		numLoans = 1;
	}
	
	function newAsk(uint amount, uint hourlyReturn, uint numHours) returns (uint) {
		Ask ask = asks[numAsks++];
		ask.amount = amount;
		ask.hourlyReturn = hourlyReturn;
		ask.asker = msg.sender;
		ask.duration = numHours;
		return numAsks-1;
	}
	
	function sendLoan(uint askId, uint amount) returns (uint) {
		deposit();
		forceCollection(msg.sender); //can't loan out to others when you have outstanding payments
		Ask ask = asks[askId];
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
			return numLoans-1;
		}
		return 0;
	}
	
	function collect(uint loanId) {
		collectTime(loanId, now);
	}

	//TODO: make private, was useful to be public for testing
	//returns how much is collected
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
	
	function payDownLoan(uint loanId) {
		Loan loan = loans[loanId];
		if (msg.sender != loan.ask.asker) {
			return ;
		}
		deposit(); //this prepay action may include funds to execute
		
		//force interest collection
		collect(loanId);
		
		payPrinciple(loanId);
	}
	
	//assumes it's okay to pay now, due to borrower opt-in or due date passed
	function payPrinciple(uint loanId) private {
		Loan loan = loans[loanId];
		//don't prepay before outstanding debts are covered
		forceCollection(loan.ask.asker);
		uint amount = loan.principle;
		if (amount > balances[loan.ask.asker]) {
			amount = balances[loan.ask.asker];
		}
		transfer(loan.ask.asker, loan.lender, amount);
		loan.principle -= amount;
	}
	
	function forceCollection(address fromUser) {
		//TODO for each open loan, collect()
	}
	
	function balance() returns (uint) {
		return balances[msg.sender];
	}
	function deposit() {
		if(msg.value > 0) {
			balances[msg.sender] += msg.value;
			forceCollection(msg.sender);
		}
	}
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
}
