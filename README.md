# ICRC-127 Bounty Library for Motoko

This library provides a compliant implementation of the [ICRC-127: Bounty Standard](https://github.com/dfinity/ICRC/pull/127). It is designed to be integrated into a host canister (like a DAO, a project's main canister, or a dedicated bounty board) to create a robust, on-chain, and trustless bounty system on the Internet Computer.

Built using the `class-plus` pattern, this library is modular, stateful, and easily upgradeable. It manages its own stable state while allowing the host canister to provide essential services—such as token transfers, validation logic, and logging—through a clean, hook-based interface.

## Features

*   **Full ICRC-127 Compliance:** Implements all required functions and behaviors, including `icrc127_create_bounty`, `icrc127_submit_bounty`, `icrc127_get_bounty`, and `icrc10_supported_standards`.
*   **Flexible Validation:** Uses a `validate_submission` hook, allowing the host canister to define its own custom logic for verifying a bounty claim. This can range from a simple internal check to a complex inter-canister call.
*   **Token Agnostic:** Supports any ICRC-1 or ICRC-2 compliant token ledger through `icrc1_transfer` and `icrc2_transfer_from` hooks. The host canister provides the transfer logic.
*   **Automated Expiration & Refunds:** Integrates with `mo:timer-tool` to automatically handle bounty timeouts, ensuring funds are safely refunded to the creator if a bounty is not claimed.
*   **Automatic ICRC-3 Logging:** Automatically creates a transparent audit trail by logging `127bounty`, `127submit_bounty`, `127bounty_run`, and `127bounty_expired` blocks to the host's provided ICRC-3 logger.
*   **Stable State Management:** Manages its own state in stable memory, ensuring all bounty data persists across canister upgrades.

## Installation

This library is designed to be used as a Git submodule or through a package manager like `mops`.

1.  Navigate to the root of your project and run:
    ```bash
    git submodule add <repository_url> libs/icrc127
    ```

2.  Ensure your build system (e.g., `dfx.json` or `mops.toml`) is configured to include the `libs/icrc127` path.

## Usage

To use the library, you instantiate it within your host canister and provide the necessary environment hooks.

### Example Host Canister (`Main.mo`)

```motoko
import Principal "mo:base/Principal";
import ClassPlus "mo:class-plus";
import ICRC3 "mo:icrc3-mo"; // Your ICRC-3 logger library
import TimerTool "mo:timer-tool"; // Your TimerTool instance
import ICRC1 "mo:icrc1/main";
import ICRC2 "mo:icrc2-types/main";

// 1. Import the library and its service definition
import ICRC127 "libs/icrc127/src/lib";
import ICRC127Service "libs/icrc127/src/service";

actor class MyBountyHost<system>(...) {
  // ... other state and setup ...
  stable var icrc127_migration_state: ICRC127.State = ICRC127.initialState();
  let tt = TimerTool.Init<system>(...); // Your TimerTool setup

  // 2. Instantiate the ICRC-127 library
  let icrc127 = ICRC127.Init<system>({
    manager = initManager; // Your ClassPlus manager
    initialState = icrc127_migration_state;
    args = null;
    onStorageChange = func(state) { icrc127_migration_state := state; };
    onInitialize = null;

    // 3. Provide the environment via the pullEnvironment hook
    pullEnvironment = ?func(): ICRC127.Environment {
      {
        tt = tt();
        advanced = null;
        log = localLog(); // Your local logger instance

        // Hook to your host's ICRC-3 logger
        add_record = ?func(data, meta) { /* ... */ };

        // Hook to your host's token transfer logic
        icrc1_transfer = func(canister, args) { /* ... call the token canister ... */ };
        icrc2_transfer_from = func(canister, args) { /* ... call the token canister ... */ };

        // Hook to your custom validation logic
        validate_submission = func(req: ICRC127Service.RunBountyRequest): async ICRC127Service.RunBountyResult {
          // Example: simple validation
          if (req.submission == req.challenge_parameters) {
            { result = #Valid; metadata = []; trx_id = null; }
          } else {
            { result = #Invalid; metadata = []; trx_id = null; }
          }
        };
      };
    };
  });

  // 4. Initialize the library's timer handler
  ICRC127.initialize_bounty_timers({
    tt = tt();
    handler = icrc127().handle_bounty_expiration;
  });

  // 5. Expose the library's functions as public endpoints
  public shared(msg) func icrc127_create_bounty(req: ICRC127Service.CreateBountyRequest): async ICRC127Service.CreateBountyResult {
    await icrc127().icrc127_create_bounty(msg.caller, req);
  };

  public shared(msg) func icrc127_submit_bounty(req: ICRC127Service.BountySubmissionRequest): async ICRC127Service.BountySubmissionResult {
    await icrc127().icrc127_submit_bounty(msg.caller, req);
  };

  public query func icrc127_get_bounty(bounty_id: Nat): async ?ICRC127.Bounty {
    await icrc127().icrc127_get_bounty(bounty_id);
  };
}
```

### The `Environment` Explained

The `pullEnvironment` function is the core of the integration. It allows the host canister to securely provide the necessary dependencies to the library at runtime.

| Field                 | Type                                                              | Description                                                                                                                                                           |
| --------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tt`                  | `TimerTool`                                                       | **Required.** An instance of `mo:timer-tool` for scheduling bounty expirations.                                                                                       |
| `add_record`          | `?(ICRC16, ?ICRC16) -> Nat`                                       | **Required.** A function that calls the host's ICRC-3 logger. The library uses this to log all bounty lifecycle events.                                                |
| `icrc1_transfer`      | `(Principal, ICRC1.TransferArgs) -> async ICRC1.TransferResult`   | **Required.** An async function that performs an ICRC-1 transfer. Used for refunding expired bounties.                                                                |
| `icrc2_transfer_from` | `(Principal, ICRC2.TransferFromArgs) -> async ICRC2.TransferFromResult` | **Required.** An async function that performs an ICRC-2 transfer. Used for escrowing funds when a bounty is created and paying out a successful claimant. |
| `validate_submission` | `(RunBountyRequest) -> async RunBountyResult`                     | **Required.** An async function that contains the host's custom logic for validating a bounty submission.                                                             |
| `log`                 | `Local_log`                                                       | An instance of `mo:stable-local-log` for debug logging.                                                                                                               |

## License

This library is licensed under the MIT License.