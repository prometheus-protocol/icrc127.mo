// libs/icrc127/src/lib.mo
import ClassPlusLib "mo:class-plus";
import MigrationTypes "migrations/types";
import MigrationLib "migrations";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Array "mo:base/Array";
import D "mo:base/Debug";
import Option "mo:base/Option";
import Buffer "mo:base/Buffer";
import Nat "mo:base/Nat";
import Star "mo:star/star";
import ovsfixed "mo:ovs-fixed";
import MapLib "mo:map/Map";
import SetLib "mo:map/Set";
import BTreeLib "mo:stableheapbtreemap/BTree";
import Result "mo:base/Result";
import Int "mo:base/Int";
import Nat8 "mo:base/Nat8";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import ICRC2 "mo:icrc2-types";

// Import local library files
import Service "service";

module {
  // --- Export Types for consumers ---
  public let Migration = MigrationLib;
  public let TT = MigrationLib.TimerTool;
  public let Map = MapLib;
  public let BTree = BTreeLib;
  public let Set = SetLib;
  public type State = MigrationTypes.State;
  public type CurrentState = MigrationTypes.Current.State;
  public type Environment = MigrationTypes.Current.Environment;
  public type InitArgs = MigrationTypes.Current.InitArgs;
  public type ICRC16Map = MigrationTypes.Current.ICRC16Map;
  public type ICRC16 = MigrationTypes.Current.ICRC16;
  public type Bounty = MigrationTypes.Current.Bounty;
  public type ClaimRecord = MigrationTypes.Current.ClaimRecord;
  public type Account = MigrationTypes.Current.Account;

  public let ICRC85_Timer_Namespace = "icrc85:ovs:shareaction:icrc127";
  public let ICRC85_Payment_Namespace = "org.icdevs.libraries.icrc127";

  public let ICRC127_Timer_Namespace = "icrc127:bounty:bounty-expired:icrc127";

  public let init = Migration.migrate;
  public func initialState() : State { #v0_0_0(#data) };
  public let currentStateVersion = #v0_1_0(#id);

  // --- ClassPlus Initialization ---
  public func Init<system>(
    config : {
      manager : ClassPlusLib.ClassPlusInitializationManager;
      initialState : State;
      args : ?InitArgs;
      pullEnvironment : ?(() -> Environment);
      onInitialize : ?(ICRC127Bounty -> async* ());
      onStorageChange : ((State) -> ());
    }
  ) : () -> ICRC127Bounty {
    let instance = ClassPlusLib.ClassPlus<system, ICRC127Bounty, State, InitArgs, Environment>({
      config with constructor = ICRC127Bounty
    }).get;

    instance().environment.tt.registerExecutionListenerAsync(
      ?ICRC127_Timer_Namespace,
      instance().handleBountyExpiration,
    );

    ovsfixed.initialize_cycleShare<system>({
      namespace = ICRC85_Timer_Namespace;
      icrc_85_state = instance().state.icrc85;
      wait = null;
      registerExecutionListenerAsync = instance().environment.tt.registerExecutionListenerAsync;
      setActionSync = instance().environment.tt.setActionSync;
      existingIndex = instance().environment.tt.getState().actionIdIndex;
      handler = instance().handleIcrc85Action;
    });
    instance;
  };

  // --- The Main Class ---
  public class ICRC127Bounty(
    stored : ?State,
    instantiator : Principal,
    canister : Principal,
    _args : ?InitArgs,
    environment_passed : ?Environment,
    storageChanged : (State) -> (),
  ) {

    // --- Private Helpers ---
    // This is your excellent implementation.
    private func natFromBytesBE(bytes : [Nat8]) : Nat {
      var result : Nat = 0;
      for (byte in bytes.vals()) {
        result := Nat.bitshiftLeft(result, 8);
        result := result + Nat8.toNat(byte);
      };
      return result;
    };

    private func natToBlobBE(len : Nat, n : Nat) : Blob {
      let ith_byte = func(i : Nat) : Nat8 {
        assert (i < len);
        let shift : Nat = 8 * (len - 1 - i);
        Nat8.fromIntWrap(n / 2 ** shift);
      };
      Blob.fromArray(Array.tabulate<Nat8>(len, ith_byte));
    };

    private func getICRC16Field(map : ICRC16Map, key : Text) : ?ICRC16 {
      for ((k, v) in map.vals()) { if (k == key) return ?v };
      null;
    };

    private func getRequiredPrincipal(map : ICRC16Map, key : Text) : Result.Result<Principal, Text> {
      switch (getICRC16Field(map, key)) {
        case (null) { return #err("Missing required metadata field: " # key) };
        case (?#Principal(p)) { return #ok(p) };
        case (?#Blob(b)) {
          #ok(Principal.fromBlob(b));
        };
        case (_) {
          return #err("Invalid type for metadata field: " # key # ", expected Principal or Blob");
        };
      };
    };

    private func getRequiredNat(map : ICRC16Map, key : Text) : Result.Result<Nat, Text> {
      switch (getICRC16Field(map, key)) {
        case (null) { return #err("Missing required metadata field: " # key) };
        case (?#Nat(n)) { return #ok(n) };
        case (_) {
          return #err("Invalid type for metadata field: " # key # ", expected Nat");
        };
      };
    };

    private func natNow() : Nat {
      return Int.abs(Time.now());
    };

    // --- Core ICRC-127 Logic ---

    public func icrc127_create_bounty<system>(caller : Principal, req : Service.CreateBountyRequest) : async Service.CreateBountyResult {
      // 1. Extract required token info from metadata
      let token_canister_id = switch (getRequiredPrincipal(req.bounty_metadata, "icrc127:reward_canister")) {
        case (#err(e)) { return #Error(#Generic(e)) };
        case (#ok(p)) { p };
      };
      let token_amount = switch (getRequiredNat(req.bounty_metadata, "icrc127:reward_amount")) {
        case (#err(e)) { return #Error(#Generic(e)) };
        case (#ok(n)) { n };
      };

      // 2. Pull funds into escrow using standard ICRC-2 arguments
      let from_account : Account = { owner = caller; subaccount = null };
      let self_account : Account = { owner = canister; subaccount = null };
      let transfer_args : ICRC2.TransferFromArgs = {
        spender_subaccount = null;
        from = from_account;
        to = self_account;
        amount = token_amount;
        fee = null;
        memo = null;
        created_at_time = null;
      };
      let transfer_res = await environment.icrc2_transfer_from(token_canister_id, transfer_args);

      let trx_id = switch (transfer_res) {
        case (#Err(e)) { return #Error(#InsufficientAllowance) }; // Simplified error mapping
        case (#Ok(id)) { id };
      };

      // 3. Create and store the bounty record
      let bounty_id = state.next_bounty_id;
      state.next_bounty_id += 1;
      let bounty : Bounty = {
        bounty_id = bounty_id;
        creator = caller;
        token_canister_id = token_canister_id;
        token_amount = token_amount;
        validation_canister_id = req.validation_canister_id;
        validation_call_timeout = 10_000_000_000; // Default 10s
        bounty_metadata = req.bounty_metadata;
        challenge_parameters = req.challenge_parameters;
        timeout_date = ?req.timeout_date;
        claimed = null;
        claims = [];
        created = natNow();
        claimed_date = null;
      };
      ignore BTree.insert(state.bounties, Nat.compare, bounty_id, bounty);

      // --- Schedule the expiration timer ---

      // This is the action record, without the time.
      // The field name must be 'params' to match the TimerTool's type.
      let actionRequest = {
        actionType = ICRC127_Timer_Namespace;
        params = natToBlobBE(8, bounty_id);
      };
      // Call setActionSync with two arguments: time and the action record.
      let action_id = environment.tt.setActionSync<system>(req.timeout_date, actionRequest);
      ignore BTree.insert(state.expiration_timers, Nat.compare, bounty_id, action_id);

      // --- 4. Log to ICRC-3 (if available) ---
      switch (environment.add_record) {
        case (null) { /* no logger, do nothing */ };
        case (?add_record) {
          let tx_buf = Buffer.Buffer<(Text, ICRC16)>(7);
          tx_buf.add(("caller", #Principal(caller)));
          tx_buf.add(("validation_canister_id", #Principal(req.validation_canister_id)));
          tx_buf.add(("validation_call_timeout", #Nat(bounty.validation_call_timeout)));
          tx_buf.add(("challenge_params", bounty.challenge_parameters));
          tx_buf.add(("bounty_metadata", #Map(req.bounty_metadata)));
          tx_buf.add(("bounty_timeout_date", #Nat(req.timeout_date)));
          switch (req.start_date) {
            case (?t) { tx_buf.add(("bounty_start_date", #Nat(t))) };
            case _ {};
          };

          let tx = Buffer.toArray(tx_buf);
          let meta : ICRC16Map = [("btype", #Text("127bounty"))];
          ignore add_record<system>(#Map(tx), ?#Map(meta));
        };
      };
      // --- End Logging ---

      return #Ok({ bounty_id = bounty_id; trx_id = ?trx_id });
    };

    public func icrc127_submit_bounty(caller : Principal, req : Service.BountySubmissionRequest) : async Service.BountySubmissionResult {
      // 1. Find the bounty
      let original_bounty = switch (BTree.get(state.bounties, Nat.compare, req.bounty_id)) {
        case (null) { return #Error(#NoMatch) };
        case (?b) { b };
      };

      // 2. Check if bounty is available
      if (original_bounty.claimed != null) {
        return #Error(#Generic("Bounty already claimed."));
      };
      // TODO: Check timeout_date

      // 3. Log the submission attempt (`127submit_bounty`)
      let claim_id = original_bounty.claims.size() + 1;
      switch (environment.add_record) {
        case (null) {};
        case (?add_record) {
          let submission_account_icrc16 = Option.map<Account, ICRC16>(
            req.account,
            func(a : Account) : ICRC16 {
              // This nested map correctly handles the optional subaccount.
              let subaccount_icrc16 = Option.map<Blob, ICRC16>(a.subaccount, func(b) { #Blob(b) });

              // Now all types are correct.
              return #Array([
                #Principal(a.owner),
                #Option(subaccount_icrc16),
              ]);
            },
          );

          let tx : ICRC16Map = [
            ("bounty_id", #Nat(req.bounty_id)),
            ("caller", #Principal(caller)),
            ("submission", req.submission),
            ("submission_account", #Option(submission_account_icrc16)),
          ];
          let meta : ICRC16Map = [("btype", #Text("127submit_bounty"))];
          ignore add_record<system>(#Map(tx), ?#Map(meta));
        };
      };

      // 4. Run the validation first to get the result
      let run_req : Service.RunBountyRequest = {
        bounty_id = req.bounty_id;
        submission_id = claim_id;
        submission = req.submission;
        challenge_parameters = original_bounty.challenge_parameters;
      };
      let run_result = await environment.validate_submission(run_req);

      // 4. Create the new, immutable claim record with the result included
      let new_claim_record : ClaimRecord = {
        claim_id = claim_id;
        time_submitted = natNow();
        caller = caller;
        claim_account = req.account;
        submission = req.submission;
        claim_metadata = []; // Or from run_result.metadata if needed
        result = ?run_result;
      };

      // 5. Log the validation result (`127bounty_run`)
      switch (environment.add_record) {
        case (null) {};
        case (?add_record) {
          let tx : ICRC16Map = [
            ("bounty_id", #Nat(req.bounty_id)),
            ("claim_id", #Nat(claim_id)),
            ("result", #Text(switch (run_result.result) { case (#Valid) "Valid"; case (#Invalid) "Invalid" })),
            ("run_metadata", run_result.metadata),
          ];
          let meta : ICRC16Map = [("btype", #Text("127bounty_run"))];
          ignore add_record<system>(#Map(tx), ?#Map(meta));
        };
      };

      // 6. Process payout and create the final, updated bounty record
      switch (run_result.result) {
        case (#Valid) {
          // This is the success path. Pay the claimant.
          let claimant_account = Option.get(req.account, { owner = caller; subaccount = null });
          let payout_args : ICRC2.TransferArgs = {
            to = claimant_account;
            amount = original_bounty.token_amount;
            fee = null;
            memo = null;
            created_at_time = null;
            from_subaccount = null;
          };
          let payout_res = await environment.icrc1_transfer(original_bounty.token_canister_id, payout_args);
          // TODO: Handle payout error, maybe revert claim?

          // Create a new bounty record with the updated claim status and new claim
          let final_bounty : Bounty = {
            original_bounty with
            claims = Array.append(original_bounty.claims, [new_claim_record]);
            claimed = ?claim_id;
            claimed_date = ?natNow();
          };

          // Replace the old bounty record with the new one in the BTree
          ignore BTree.insert(state.bounties, Nat.compare, req.bounty_id, final_bounty);
        };
        case (#Invalid) {
          // This is the failure path. No payout.
          // Create a new bounty record with just the new (failed) claim added.
          let final_bounty : Bounty = {
            original_bounty with
            claims = Array.append(original_bounty.claims, [new_claim_record]);
          };

          // Replace the old bounty record with the new one
          ignore BTree.insert(state.bounties, Nat.compare, req.bounty_id, final_bounty);
        };
      };

      // TODO: Log submission and run result to ICRC-3

      return #Ok({ claim_id = claim_id; result = ?run_result });
    };

    // --- Query Functions ---
    public func icrc127_get_bounty(bounty_id : Nat) : ?Bounty {
      BTree.get(state.bounties, Nat.compare, bounty_id);
    };

    public func icrc127_list_bounties(filter : ?[Service.ListBountiesFilter], prev : ?Nat, take : ?Nat) : [Bounty] {
      // TODO: Implement filtering and pagination
      let bounties_array = BTree.toArray(state.bounties);
      Array.map<(Nat, Bounty), Bounty>(bounties_array, func((_ : Nat, bounty : Bounty)) { bounty });
    };

    public func icrc127_metadata() : ICRC16Map {
      [("icrc127:canister_type", #Text("bounty"))];
    };

    public func icrc10_supported_standards() : [{
      name : Text;
      url : Text;
    }] {
      [
        { name = "ICRC-10"; url = "..." },
        { name = "ICRC-127"; url = "..." },
      ];
    };

    // --- Boilerplate ---
    public let environment = switch (environment_passed) {
      case (?val) val;
      case (null) { D.trap("Environment is required") };
    };
    public var state : CurrentState = switch (stored) {
      case (null) {
        let #v0_1_0(#data(s)) = init(initialState(), currentStateVersion, null, instantiator, canister);
        s;
      };
      case (?val) {
        let #v0_1_0(#data(s)) = init(val, currentStateVersion, null, instantiator, canister);
        s;
      };
    };
    let _ = storageChanged(#v0_1_0(#data(state)));

    // --- Dedicated public handler for expiration timers ---
    // The host canister will register this function as a listener with the TimerTool.
    public func handleBountyExpiration(id : TT.ActionId, action : TT.Action) : async* Star.Star<TT.ActionId, TT.Error> {
      Debug.print("Handling bounty expiration for ID: ");
      let bounty_id = natFromBytesBE(Blob.toArray(action.params));

      // Find the bounty to expire
      let bounty = switch (BTree.get(state.bounties, Nat.compare, bounty_id)) {
        case (null) { return #trappable(id) }; // Bounty already processed/removed
        case (?b) { b };
      };

      // Safety check: only expire unclaimed bounties
      if (bounty.claimed == null) {
        // Refund the creator
        let refund_args : ICRC2.TransferArgs = {
          to = { owner = bounty.creator; subaccount = null };
          amount = bounty.token_amount;
          fee = null;
          memo = ?Blob.fromArray(Blob.toArray(Text.encodeUtf8("ICRC-127 Bounty Refund")));
          created_at_time = null;
          from_subaccount = null;
        };
        let refund_res = await environment.icrc1_transfer(bounty.token_canister_id, refund_args);

        // Log the expiration event
        switch (environment.add_record) {
          case (?add_record) {
            let tx_buf = Buffer.Buffer<(Text, ICRC16)>(3);
            tx_buf.add(("bounty_id", #Nat(bounty_id)));
            switch (refund_res) {
              case (#Ok(trx)) { tx_buf.add(("refund_trx", #Nat(trx))) };
              case (#Err(e)) {
                tx_buf.add(("refund_error", #Text(debug_show e)));
              };
            };
            let meta : ICRC16Map = [("btype", #Text("127bounty_expired"))];
            ignore add_record<system>(#Map(Buffer.toArray(tx_buf)), ?#Map(meta));
          };
          case _ {};
        };

        // Clean up state
        ignore BTree.delete(state.bounties, Nat.compare, bounty_id);
        ignore BTree.delete(state.expiration_timers, Nat.compare, bounty_id);
      };
      #awaited(id);
    };

    ///////////
    // ICRC85 ovs
    //////////
    public func handleIcrc85Action<system>(id : TT.ActionId, action : TT.Action) : async* Star.Star<TT.ActionId, TT.Error> {
      switch (action.actionType) {
        case (ICRC85_Timer_Namespace) {
          await* ovsfixed.standardShareCycles({
            icrc_85_state = state.icrc85;
            icrc_85_environment = do ? { environment.advanced!.icrc85! };
            setActionSync = environment.tt.setActionSync;
            timerNamespace = ICRC85_Timer_Namespace;
            paymentNamespace = ICRC85_Payment_Namespace;
            baseCycles = 1_000_000_000_000; // 1 XDR
            maxCycles = 100_000_000_000_000; // 1 XDR
            actionDivisor = 10000;
            actionMultiplier = 200_000_000_000; // .2 XDR
          });
          #awaited(id);
        };
        case (_) #trappable(id);
      };
    };
  };
};
