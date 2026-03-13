# 🛡️ AEGIS-V3 Sentinel

[![Drosera Network](https://img.shields.io/badge/Drosera-Network-6C47FF?style=for-the-badge&logo=ethereum&logoColor=white)](https://drosera.io)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.33-363636?style=for-the-badge&logo=solidity&logoColor=white)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF6B35?style=for-the-badge)](https://getfoundry.sh)
[![Network](https://img.shields.io/badge/Network-Hoodi%20Testnet-0052FF?style=for-the-badge)](https://hoodi.etherscan.io)
[![Version](https://img.shields.io/badge/Version-v2.0-brightgreen?style=for-the-badge)](https://github.com/DAOmindbreaker/aegis-v3-sentinel)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

> **Lido V3 VaultHub Risk Sentinel** — Real-time on-chain monitoring for the Lido V3 stVaults ecosystem, powered by [Drosera Network](https://drosera.io).

---

## 📌 Overview

AEGIS-V3 is a production-grade [Drosera trap](https://docs.drosera.io) that continuously monitors the **Lido V3 VaultHub** smart contract for systemic risk signals. It samples vault health across a distributed index space, cross-checks the Accounting contract for external shares ratio, tracks wstETH redemption rate degradation across a 3-snapshot window, and fires early-warning alerts before critical thresholds are reached — all in a single, gas-optimized trap execution.

### Why AEGIS-V3?

Lido V3 introduces a fundamentally new architecture — **stVaults** — where third-party operators create isolated staking vaults connected to a central VaultHub. This creates new attack surfaces that didn't exist in Lido V1/V2:

- If multiple vaults become undercollateralized simultaneously, bad debt can **cascade into VaultHub** and affect the entire stETH system
- A protocol pause would **freeze billions in staked ETH** with no on-chain early warning
- External shares minting from stVaults can **exceed the protocol cap**, creating unbacked stETH before bad debt is formally registered
- wstETH redemption rate degradation can signal **accounting manipulation or systemic insolvency** before it becomes visible to users

The `LidoProtocolAnomalySentinel` monitors Lido V1/V2 pooled ETH at the macro level. AEGIS-V3 goes deeper — **monitoring the V3 vault layer in real time**, where the next systemic risk is most likely to originate.

---

## ⚡ Live Deployment (Hoodi Testnet)

| Contract | Address | Explorer |
|---|---|---|
| **AegisV3Sentinel** (Trap) | `0x047aEdd2215C6E22E1a8128A9A98735FfF666aff` | [View ↗](https://hoodi.etherscan.io/address/0x047aEdd2215C6E22E1a8128A9A98735FfF666aff) |
| **AegisV3Response** | `0x6A389da253A1D4B0fA5f5b0fe6843164398e9f45` | [View ↗](https://hoodi.etherscan.io/address/0x6A389da253A1D4B0fA5f5b0fe6843164398e9f45) |
| **VaultHub** (Monitored) | `0x4C9fFC325392090F789255b9948Ab1659b797964` | [View ↗](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964) |
| **Accounting** (Monitored) | `0x9b5b78D1C9A3238bF24662067e34c57c83E8c354` | [View ↗](https://hoodi.etherscan.io/address/0x9b5b78D1C9A3238bF24662067e34c57c83E8c354) |
| **stETH** (Monitored) | `0x3508A952176b3c15387C97BE809eaffB1982176a` | [View ↗](https://hoodi.etherscan.io/address/0x3508A952176b3c15387C97BE809eaffB1982176a) |
| **wstETH** (Monitored) | `0x7E99eE3C66636DE415D2d7C880938F2f40f94De4` | [View ↗](https://hoodi.etherscan.io/address/0x7E99eE3C66636DE415D2d7C880938F2f40f94De4) |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Drosera Network                            │
│  ┌─────────────┐    attestation    ┌────────────────────────┐   │
│  │  Operators  │◄─────────────────►│   Drosera Protocol     │   │
│  └──────┬──────┘                   └────────────────────────┘   │
│         │ execute every block                                   │
└─────────┼─────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                  AegisV3Sentinel v2 (Trap)                      │
│                                                                 │
│  collect()               shouldRespond()      shouldAlert()     │
│  ┌─────────────────┐    ┌───────────────┐    ┌──────────────┐  │
│  │ VaultHub:       │    │ Check A:      │    │ Alert A:     │  │
│  │ • vaultsCount   │    │ Bad Debt > 0  │    │ Any unhealthy│  │
│  │ • badDebt       │    │ (CRITICAL)    │    │ vault (≥1)   │  │
│  │ • isPaused      │──► │ Check B:      │    │ Alert B:     │  │
│  │ • 25 vaults     │    │ Pause change  │    │ Rate drop    │  │
│  │   (stride)      │    │ (CRITICAL)    │    │ >100 bps     │  │
│  │                 │    │ Check C:      │    │ Alert C:     │  │
│  │ Accounting:     │    │ ≥3 unhealthy  │    │ ExtRatio     │  │
│  │ • externalShares│    │ (HIGH)        │    │ near cap     │  │
│  │ • maxRatioBP    │    │ Check D:      │    │ Alert D:     │  │
│  │                 │    │ Rate drop     │    │ Pre-bad-debt │  │
│  │ stETH + wstETH: │    │ >300 bps      │    │ shortfall    │  │
│  │ • pooledEther   │    │ (HIGH)        │    └──────────────┘  │
│  │ • totalShares   │    │ Check E:      │                      │
│  │ • wstEthRate    │    │ ExtRatio      │                      │
│  └─────────────────┘    │ breach        │                      │
│                         │ (CRITICAL)    │                      │
│                         └──────┬────────┘                      │
└──────────────────────────────┬─┼───────────────────────────────┘
                               │ │ should_respond = true
                               ▼ ▼
┌─────────────────────────────────────────────────────────────────┐
│               AegisV3Response (Response Contract)               │
│                                                                 │
│  recordBadDebt(uint256,uint256,uint256)        → CRITICAL       │
│  recordProtocolPause(uint256,uint256)          → CRITICAL       │
│  recordVaultHealthDegradation(uint256,uint256,uint256) → HIGH   │
│  recordRedemptionRateDrop(uint256,uint256,uint256)     → HIGH   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔍 How It Works

### Data Collection (`collect()`)

Every block, the sentinel reads a full ecosystem snapshot across 4 contracts:

```solidity
struct AegisSnapshot {
    // VaultHub state
    uint256 vaultsCount;           // Total connected stVaults
    uint256 badDebt;               // Bad debt pending internalization (wei)
    bool    protocolPaused;        // VaultHub pause state
    uint256 unhealthyVaults;       // Unhealthy vaults in 25-vault sample
    uint256 totalShortfallShares;  // Aggregate shortfall across sample

    // wstETH / stETH state
    uint256 wstEthRate;            // ETH per 1e18 wstETH shares
    uint256 totalPooledEther;      // Total ETH pooled in stETH
    uint256 totalShares;           // Total stETH shares outstanding
    uint256 shareRatioBps;         // Share-to-pooled ratio (bps)

    // Accounting cross-check (new in v2)
    uint256 externalShares;        // Shares minted against stVault collateral
    uint256 maxExternalRatioBp;    // Protocol cap for external shares (bps)
    uint256 externalRatioBps;      // Actual external ratio (bps)

    bool    valid;                 // Snapshot validity flag
}
```

### Adaptive Vault Sampling (v2)

v2 samples **25 vaults** using a **stride pattern** for distributed coverage:

```
vaultsCount = 532, sampleSize = 25
stride = 532 / 25 = 21

Sampled indices: 0, 21, 42, 63, 84, ..., 504
Coverage: ~5% of all registered vaults, evenly distributed
```

This avoids clustering at index 0 (oldest vaults) and gives a representative cross-section of the entire stVaults ecosystem.

### Risk Detection (`shouldRespond()`)

Five independent checks across a **3-snapshot window**:

| Check | Signal | Threshold | Severity |
|---|---|---|---|
| **A — Bad Debt** | `badDebtToInternalize() > 0` | Any bad debt | 🔴 CRITICAL |
| **B — Protocol Pause** | `isPaused()` state change | `false → true` | 🔴 CRITICAL |
| **C — Vault Health** | Unhealthy vaults in 25-sample | ≥ 3 of 25 (12%) sustained | 🟠 HIGH |
| **D — Rate Drop** | wstETH/stETH rate decline | > 300 bps, 3-block confirmed | 🟠 HIGH |
| **E — External Ratio** *(new)* | externalShares / totalShares > cap | Sustained breach × 3 blocks | 🔴 CRITICAL |

### Early Warning System (`shouldAlert()`) — new in v2

Four pre-threshold alerts fire **before** the hard triggers:

| Alert | Signal | Threshold | Purpose |
|---|---|---|---|
| **A** | Any unhealthy vault | ≥ 1 vault | Early degradation signal |
| **B** | wstETH rate drop | > 100 bps | Soft warning before 300 bps trigger |
| **C** | External ratio near cap | Within 500 bps of cap | Approaching limit warning |
| **D** | Pre-bad-debt shortfall | shortfallShares > 0, badDebt = 0 | Bad debt imminent signal |

---

## 📊 Performance Stats

### v1 vs v2 Comparison

| Metric | v1 | v2 | Change |
|---|---|---|---|
| Vault sample size | 10 | 25 | +150% coverage |
| Sampling pattern | Sequential | Stride | Distributed |
| Contracts monitored | 3 | 4 | +Accounting |
| Detection checks | 4 | 5 | +Check E |
| Alert signals | 0 | 4 | New in v2 |
| `collect()` gas | 385,516 | 915,480 | Expected increase |
| `shouldRespond()` gas | 58,800 | 71,570 | +Check E logic |
| Slots queried | 65 | 155 | 2.4× deeper |

### Live Dryrun (block `2409066`)

| Metric | Value |
|---|---|
| `collect()` gas used | 915,480 |
| `shouldRespond()` gas used | 71,570 |
| `shouldAlert()` gas used | 0 *(protocol healthy)* |
| Accounts queried | 8 |
| Storage slots queried | 155 |
| Bootstrap duration | ~29s |
| Runtime duration | ~570ms |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh) installed
- [Drosera CLI](https://docs.drosera.io) installed
- Hoodi testnet ETH (faucet: [hoodi.ethpandaops.io](https://hoodi.ethpandaops.io))

### Installation

```bash
git clone https://github.com/DAOmindbreaker/aegis-v3-sentinel.git
cd aegis-v3-sentinel
forge install
forge build
```

### Run Dryrun

```bash
drosera dryrun
```

Expected output:
```
should_respond: false     ← normal when protocol is healthy
should_alert:   false     ← normal when no pre-threshold conditions
collect() gas used: 915,480
shouldRespond() gas used: 71,570
slots queried: 155 | accounts: 8
```

### Deploy Response Contract

```bash
export PRIVATE_KEY=0xYOUR_PRIVATE_KEY

forge create src/AegisV3Response.sol:AegisV3Response \
  --rpc-url https://ethereum-hoodi-rpc.publicnode.com \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args YOUR_OPERATOR_ADDRESS
```

### Configure & Apply Trap

Update `drosera.toml` with your deployed response contract address, then:

```bash
export DROSERA_PRIVATE_KEY=$PRIVATE_KEY
drosera apply
```

---

## 📁 Project Structure

```
aegis-v3-sentinel/
├── src/
│   ├── AegisV3Sentinel.sol     # Main trap — collection, detection & alerting
│   └── AegisV3Response.sol     # Response contract — on-chain incident logging
├── test/
│   └── (tests coming soon)
├── drosera.toml                # Trap configuration
├── foundry.toml                # Foundry configuration
└── README.md
```

---

## 📋 Changelog

### v2.0
- **Adaptive vault sampling**: increased from 10 → 25 vaults with stride pattern for distributed coverage
- **Accounting cross-check**: new Check E monitors external shares ratio against protocol cap
- **Rate degradation history**: Check D now uses full 3-snapshot window for sustained decline confirmation
- **shouldAlert()**: 4 early warning signals before hard trigger thresholds
- **AegisSnapshot expanded**: added `externalShares`, `maxExternalRatioBp`, `externalRatioBps`, `totalShares`

### v1.0
- Initial release: 4 detection checks (bad debt, pause, vault health, rate drop)
- 10-vault sequential sampling
- VaultHub + stETH + wstETH monitoring

---

## 🤝 Contributing

Contributions are welcome! Here's how to get started:

1. **Fork** this repository
2. **Create** a feature branch: `git checkout -b feat/your-feature`
3. **Build** and verify: `forge build` (must be zero errors)
4. **Dryrun** your changes: `drosera dryrun`
5. **Commit** with clear message: `git commit -m "feat: describe your change"`
6. **Open a Pull Request** with description of what was changed and why

### Ideas for Contributions

- [ ] Mainnet deployment configuration
- [ ] Expand vault sampling with dynamic stride adjustment
- [ ] Add Aave V3 integration for cross-protocol risk correlation
- [ ] Add Uniswap V3 wstETH/ETH pool monitoring
- [ ] Add Curve stETH/ETH pool imbalance detection
- [ ] Write comprehensive Foundry tests
- [ ] AegisV3Response: emit structured events per check type

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 🔗 Resources

- [Drosera Network Docs](https://docs.drosera.io)
- [Lido V3 Documentation](https://docs.lido.fi)
- [VaultHub on Hoodi Explorer](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964)
- [Accounting on Hoodi Explorer](https://hoodi.etherscan.io/address/0x9b5b78D1C9A3238bF24662067e34c57c83E8c354)
- [Foundry Book](https://book.getfoundry.sh)

---

<p align="center">Built with ❤️ for the Drosera Network ecosystem</p>
