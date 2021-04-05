pragma solidity ^0.6.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.6/VRFConsumerBase.sol";

interface IUniswapRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract TokenFlip is Ownable, VRFConsumerBase {
    event Deposit(address token, address user, uint256 amount);
    event Withdraw(address token, address user, uint256 amount);
    event UpdateToken(
        address token,
        uint256 minAmountDeposit,
        uint256 minAmountWager
    );

    event GameCreated(
        uint256 indexed gameID,
        address indexed creator,
        address indexed token,
        uint256 amount
    );
    event GameDeleted(uint256 indexed gameID);
    event GameChallenged(uint256 indexed gameID, address indexed challenger);
    event GameRevealRequest(uint256 indexed gameID, bytes32 requestID);
    event GameRevealed(
        uint256 indexed gameID,
        address indexed winner,
        address token,
        uint256 amount
    );

    struct Game {
        address creator; // creator of game
        address challenger; // challenger of game
        address winner; // winner of game
        address token; // token wagered
        uint256 amount; // amount wagered - where 0 amount means a deleted game
    }

    struct Token {
        uint256 minAmountDeposit; // minimum amount deposit
        uint256 minAmountWager; // minimum amount wager for a game
    }

    mapping(uint256 => Game) public gameMap; // maps gameID to Game struct
    mapping(address => Token) public tokens; // minimum wager amount for token
    mapping(address => mapping(address => uint256)) public balances; // mapping of token addresses to mapping of account balances
    mapping(bytes32 => uint256) public gameIDsByRequestID; // maps requestID to gameID

    // VRF
    bytes32 internal vrfKeyHash;
    uint256 internal vrfFee;

    // GAME
    uint256 public gameCount = 0; // counter for gameID

    // ADDRESSES
    address public routerAddress;
    address public dividendAddress;
    address public wethAddress;
    address public dmtAddress;
    address public devAddress;

    // FEES
    uint256 public fee = 10;
    uint256 public devFee = 5;
    uint256 public denominator = 1000;

    constructor(
        address _routerAddress,
        address _dividendAddress,
        address _wethAddress,
        address _dmtAddress,
        address _devAddress
    )
        public
        VRFConsumerBase(
            0x3d2341ADb2D31f1c5530cDC622016af293177AE0, // VRF Coordinator
            0xb0897686c545045aFc77CF20eC7A532E3120E0F1 // LINK Token
        )
    {
        routerAddress = _routerAddress;
        dividendAddress = _dividendAddress;
        wethAddress = _wethAddress;
        dmtAddress = _dmtAddress;
        devAddress = _devAddress;

        vrfKeyHash = 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
        vrfFee = 100000000000000; // 0.0001 LINK
    }

    function setDividendAddress(address _dividendAddress) public onlyOwner {
        dividendAddress = _dividendAddress;
    }

    function setDevAddress(address _devAddress) public onlyOwner {
        devAddress = _devAddress;
    }

    function setToken(
        address _token,
        uint256 _minAmountDeposit,
        uint256 _minAmountWager
    ) public onlyOwner {
        Token storage token = tokens[_token];
        token.minAmountDeposit = _minAmountDeposit;
        token.minAmountWager = _minAmountWager;
        emit UpdateToken(_token, _minAmountDeposit, _minAmountWager);
    }

    function setFee(uint256 _fee) public onlyOwner {
        require(_fee <= 20); // max 2%
        fee = _fee;
    }

    function setDevFee(uint256 _devFee) public onlyOwner {
        require(_devFee <= 10); // max 1%
        devFee = _devFee;
    }

    function deposit() public payable {
        uint256 value = msg.value;

        Token storage token = tokens[address(0)];

        require(value >= token.minAmountDeposit, "Amount not reached");

        uint256 totalFee = value.mul(fee.add(devFee)).div(denominator);

        balances[address(0)][msg.sender] = balances[address(0)][msg.sender].add(
            value.sub(totalFee)
        );
        payable(devAddress).transfer(totalFee);

        emit Deposit(address(0), msg.sender, value);
    }

    function depositToken(address _token, uint256 _amount) public {
        Token storage token = tokens[_token];
        require(token.minAmountDeposit > 0, "Token not allowed");
        require(_amount >= token.minAmountDeposit, "Amount not reached");

        require(
            IERC20(_token).transferFrom(msg.sender, address(this), _amount)
        );

        if (_token == wethAddress) {
            uint256 totalFee = _amount.mul(fee).div(denominator);
            uint256 totalDevFee = _amount.mul(devFee).div(denominator);
            IERC20(_token).transfer(devAddress, totalDevFee);
            balances[_token][msg.sender] = balances[_token][msg.sender].add(
                _amount.sub(totalFee.add(totalDevFee))
            );

            address[] memory path = new address[](2);
            path[0] = wethAddress;
            path[1] = dmtAddress;

            IERC20(wethAddress).approve(routerAddress, totalFee);

            uint256[] memory amounts =
                IUniswapRouter(routerAddress).swapExactTokensForTokens(
                    totalFee.div(2),
                    0,
                    path,
                    address(this),
                    block.timestamp
                );
            uint256 wethAmount = amounts[0];
            uint256 dmtAmount = amounts[1];

            IERC20(dmtAddress).approve(routerAddress, dmtAmount);

            IUniswapRouter(routerAddress).addLiquidity(
                wethAddress,
                dmtAddress,
                wethAmount,
                dmtAmount,
                0,
                0,
                dividendAddress,
                block.timestamp
            );
        } else {
            uint256 totalFee = _amount.mul(fee.add(devFee)).div(denominator);
            IERC20(_token).transfer(devAddress, totalFee);
            balances[_token][msg.sender] = balances[_token][msg.sender].add(
                _amount.sub(totalFee)
            );
        }

        emit Deposit(_token, msg.sender, _amount);
    }

    function withdraw(address _token, uint256 _amount) public {
        require(
            balances[_token][msg.sender] >= _amount,
            "Insufficient balance"
        );

        balances[_token][msg.sender] = balances[_token][msg.sender].sub(
            _amount
        );

        if (_token == address(0)) {
            msg.sender.transfer(_amount);
        } else {
            IERC20(_token).transfer(msg.sender, _amount);
        }

        emit Withdraw(_token, msg.sender, _amount);
    }

    function getBalance(address _token) public view returns (uint256) {
        return balances[_token][msg.sender];
    }

    function createGame(address _token, uint256 _amount)
        public
        returns (uint256 gameID)
    {
        Token storage token = tokens[_token];
        require(_amount >= token.minAmountWager, "Minimum wager");
        require(
            balances[_token][msg.sender] >= _amount,
            "Insufficient balance"
        );

        balances[_token][msg.sender] = balances[_token][msg.sender].sub(
            _amount
        );

        gameCount = gameCount + 1;

        gameMap[gameCount] = Game({
            creator: msg.sender,
            challenger: address(0),
            winner: address(0),
            token: _token,
            amount: _amount
        });

        emit GameCreated(gameCount, msg.sender, _token, _amount);
        return gameCount;
    }

    function deleteGame(uint256 _gameID) external {
        Game storage game = gameMap[_gameID];

        require(game.creator == msg.sender, "Can only delete your own games");
        require(
            game.challenger == address(0),
            "Can only delete game if no challenger"
        );

        balances[game.token][msg.sender] = balances[game.token][msg.sender].add(
            game.amount
        );
        game.amount = 0;

        emit GameDeleted(_gameID);
    }

    function challengeGame(uint256 _gameID, uint256 userProvidedSeed) external {
        Game storage game = gameMap[_gameID];

        require(
            balances[game.token][msg.sender] >= game.amount,
            "Insufficient balance"
        );
        require(game.challenger == address(0), "Game already has a challenger");
        require(
            game.creator != msg.sender,
            "You can not challenge your own game"
        );
        require(game.amount != 0, "Cannot challenge a deleted game");

        balances[game.token][msg.sender] = balances[game.token][msg.sender].sub(
            game.amount
        );

        game.challenger = msg.sender;

        revealGameRequest(_gameID, userProvidedSeed);

        emit GameChallenged(_gameID, msg.sender);
    }

    function revealGameRequest(uint256 _gameID, uint256 userProvidedSeed)
        internal
    {
        Game storage game = gameMap[_gameID];

        require(game.amount != 0, "Cannot reveal a deleted game");
        require(game.winner == address(0), "Cannot reveal a finished game");
        require(
            game.challenger != address(0),
            "Cannot reveal a game with no challenger"
        );

        bytes32 requestID = getRandomNumber(userProvidedSeed);
        gameIDsByRequestID[requestID] = _gameID;

        emit GameRevealRequest(_gameID, requestID);
    }

    function revealGame(bytes32 requestID, uint256 randomness) internal {
        require(gameIDsByRequestID[requestID] != 0, "Cannot find proper game");

        uint256 _gameID = gameIDsByRequestID[requestID];
        Game storage game = gameMap[_gameID];

        if (randomness.mod(2) == 0) {
            game.winner = game.creator;
        } else {
            game.winner = game.challenger;
        }

        balances[game.token][game.winner] = balances[game.token][game.winner]
            .add(game.amount.mul(2));

        gameIDsByRequestID[requestID] = 0;

        emit GameRevealed(_gameID, game.winner, game.token, game.amount);
    }

    /**
     * Requests randomness from a user-provided seed
     */
    function getRandomNumber(uint256 userProvidedSeed)
        public
        returns (bytes32 requestID)
    {
        require(
            LINK.balanceOf(address(this)) >= vrfFee,
            "Not enough LINK - fill contract with faucet"
        );
        return requestRandomness(vrfKeyHash, vrfFee, userProvidedSeed);
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestID, uint256 randomness)
        internal
        override
    {
        revealGame(requestID, randomness);
    }
}
