// do not remove comments from this file
import MigrationTypes "../types";
import Time "mo:base/Time";
import v0_1_0 "types";
import D "mo:base/Debug";

module {

  // Version v0_1_0: Sets up initial orchestration state for ICRC-120 Canister Wasm Orchestration Service.
  // All fields initialized for safety and upgrade compatibility.
  public func upgrade(_prev_state : MigrationTypes.State, _args : MigrationTypes.Args, _caller : Principal, _canister : Principal) : MigrationTypes.State {
    // Initialize the v0_1_0.State record consistent with types.mo spec
    let state : v0_1_0.State = {
      icrc85 = {
        var nextCycleActionId = null;
        var lastActionReported = null;
        var activeActions = 0;
      };

      // ICRC-127 state
      // The main data store for all created bounties, indexed by a unique Nat.
      var bounties = v0_1_0.BTree.init<Nat, v0_1_0.Bounty>(null);

      // A simple counter to ensure every new bounty gets a unique ID.
      var next_bounty_id = 0;

      // Initialize the new empty BTree for timers.
      var expiration_timers = v0_1_0.BTree.init<Nat, v0_1_0.ActionId>(null);
    };
    return #v0_1_0(#data(state));
  };
};
