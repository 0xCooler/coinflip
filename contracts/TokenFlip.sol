pragma solidity ^0.6.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@chainlink/contracts/src/v0.6/VRFConsumerBase.sol";

contract TokenFlip is Ownable, VRFConsumerBase {
    using SafeERC20 for ERC20;

    event Deposit(address token, address user, uint256 amount);
    event Withdraw(address token, address user, uint256 amount);

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
        address creator; /// creator of game
        address challenger; /// challenger of game
        address winner; /// winner of game
        address token; /// token wagered
        uint256 amount; /// amount wagered - where 0 amount means a deleted game
    }

    mapping(uint256 => Game) public gameMap; // maps gameID to Game struct
    mapping(address => mapping(address => uint256)) public balances; //mapping of token addresses to mapping of account balances
    mapping(bytes32 => uint256) private gameIDsByRequestID; // maps requestID to gameID

    // VRF
    bytes32 internal vrfKeyHash;
    uint256 internal vrfFee;

    // GAME
    uint256 public gameCount = 0; // counter for gameID
    uint256 public minAmountDeposit = 0.01 ether; // minimum amount deposit
    uint256 public minAmountWager = 0.001 ether; // minimum amount wagered for a game
    uint256 public minBlocks = 5; // minimum number of blocks

    constructor()
        public
        VRFConsumerBase(
            0x3d2341ADb2D31f1c5530cDC622016af293177AE0, // VRF Coordinator
            0xb0897686c545045aFc77CF20eC7A532E3120E0F1 // LINK Token
        )
    {
        vrfKeyHash = 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
        vrfFee = 100000000000000; // 0.0001 LINK
    }

    function depositToken(address _token, uint256 _amount) public {
        require(_amount > minAmountDeposit, "Amount not reached");

        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 fee = _amount.div(100);

        balances[_token][msg.sender] = balances[_token][msg.sender].add(
            _amount.sub(fee)
        );
        balances[_token][this.owner()] = balances[_token][this.owner()].add(
            fee
        );

        emit Deposit(_token, msg.sender, _amount);
    }

    function deposit() public payable {
        uint256 value = msg.value;

        require(value >= minAmountDeposit, "Amount not reached");

        uint256 fee = value.div(100);

        balances[address(0)][msg.sender] = balances[address(0)][msg.sender].add(
            value.sub(fee)
        );
        balances[address(0)][this.owner()] = balances[address(0)][this.owner()]
            .add(fee);

        emit Deposit(address(0), msg.sender, value);
    }

    function withdraw(address _token, uint256 _amount) public {
        require(
            balances[_token][msg.sender] >= _amount,
            "Not enough in balance"
        );

        balances[_token][msg.sender] = balances[_token][msg.sender].sub(
            _amount
        );

        if (_token == address(0)) {
            msg.sender.transfer(_amount);
        } else {
            ERC20(_token).safeTransfer(msg.sender, _amount);
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
        require(_amount >= minAmountWager, "Minimum wager");
        require(balances[_token][msg.sender] >= _amount, "Amount in balance");

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
            balances[game.token][msg.sender] > game.amount,
            "Not enough in balance"
        );
        require(game.challenger == address(0), "Game already has a challenger");
        require(
            game.creator != msg.sender,
            "You can not challenge your own game"
        );

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
