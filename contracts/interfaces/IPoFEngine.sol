// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPoFEngine {
    struct ForecastView {
        uint64 start;
        uint64 forecastEnd;
        uint64 settledAt;
        uint8 numRungs;
        bool puzzlesPosted;
        bool settled;
    }

    function forecastEnabled() external view returns (bool);
    function forecastView(uint256 roundId) external view returns (ForecastView memory);
    function rungBucket(uint256 roundId, uint8 rung) external view returns (uint8);
    function forecastBudget(uint256 roundId) external view returns (uint256);
    function creditForecast(uint256 roundId, address user, uint256 amount) external;
    function returnForecastUnused(uint256 roundId) external;
    function creditSubsidy(address user, uint256 amount) external returns (uint256 credited);
    function reputationOf(address user) external view returns (uint256);
    function paused() external view returns (bool);
}
