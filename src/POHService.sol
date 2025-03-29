// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract POHService is ERC721 {
    struct ScoreEntry {
        uint256 score;
        uint16 calcModel;
        uint256 chainId;
    }

    mapping(address => ScoreEntry) public addressScores;
    mapping(address => bool) public guildPinHolders;
    uint256 private _tokenIdCounter;

    constructor() ERC721("POHService", "POHS") {}

    // Nomis Score Methods
    function setScore(
        address user,
        uint256 score,
        uint16 calcModel,
        uint256 chainId
    ) external {
        addressScores[user] = ScoreEntry({
            score: score,
            calcModel: calcModel,
            chainId: chainId
        });

        // Mint a token to the user for tracking
        _tokenIdCounter++;
        _safeMint(user, _tokenIdCounter);
    }

    function getScore(
        address addr,
        uint256 blockchainId,
        uint16 calcModel
    ) external view returns (uint256) {
        ScoreEntry memory entry = addressScores[addr];

        // Validate parameters
        require(
            entry.chainId == blockchainId && entry.calcModel == calcModel,
            "Invalid score parameters"
        );

        return entry.score;
    }

    // Guildpin Methods
    function setGuildPinHolder(address user) external {
        // Mint a token to simulate Guildpin
        _tokenIdCounter++;
        _safeMint(user, _tokenIdCounter);
        guildPinHolders[user] = true;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        return guildPinHolders[owner] ? 1 : 0;
    }
}
