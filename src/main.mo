// packages/canisters/icrc127/src/Main.mo
// This is a host canister for testing the ICRC-127 library,
// closely following the established class-plus pattern.

import D "mo:base/Debug";
import Principal "mo:base/Principal";
import ClassPlus "mo:class-plus";
import TT "mo:timer-tool";
import Log "mo:stable-local-log";
import ICRC3 "mo:icrc3-mo";
import Text "mo:base/Text";
import Map "mo:map/Map";
import CertTree "mo:cert/CertTree";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Nat "mo:base/Nat";

// Import the local library and its service definition
import ICRC127 "lib";
import Service "service";

// Import standard token types from Mops
import ICRC2 "mo:icrc2-types";

// The main test canister actor
shared (deployer) actor class ICRC127BountyCanister<system>(
  args : {
    icrc127Args : ?ICRC127.InitArgs;
    ttArgs : ?TT.InitArgList;
  }
) = this {

  // --- Mock Token Ledger State ---
  // For testing, we simulate a token ledger within this canister.
  stable var balances = Map.new<Principal, Nat>();
  stable var allowances = Map.new<Principal, Map.Map<Principal, Nat>>();

  // This private helper function converts the rich ICRC127 value type
  // into the simpler Value type expected by the ICRC3 logger.
  private func convertIcrc127ValueToIcrc3Value(val : ICRC127.ICRC16) : ICRC3.Value {
    switch (val) {
      case (#Nat(n)) { return #Nat(n) };
      case (#Int(i)) { return #Int(i) };
      case (#Text(t)) { return #Text(t) };
      case (#Blob(b)) { return #Blob(b) };
      case (#Array(arr)) {
        let converted_arr = Array.map<ICRC127.ICRC16, ICRC3.Value>(arr, convertIcrc127ValueToIcrc3Value);
        return #Array(converted_arr);
      };
      case (#Map(map)) {
        let converted_map = Array.map<(Text, ICRC127.ICRC16), (Text, ICRC3.Value)>(map, func((k, v)) { (k, convertIcrc127ValueToIcrc3Value(v)) });
        return #Map(converted_map);
      };
      case (#Bool(b)) { return #Text(debug_show (b)) };
      case (#Principal(p)) { return #Text(Principal.toText(p)) };
      case (_) { return #Text("Unsupported ICRC-3 Value Type") };
    };
  };

  let thisPrincipal = Principal.fromActor(this);
  stable var _owner = deployer.caller;

  let initManager = ClassPlus.ClassPlusInitializationManager(_owner, thisPrincipal, true);
  let icrc127InitArgs = args.icrc127Args;
  let ttInitArgs : ?TT.InitArgList = args.ttArgs;

  // --- TimerTool Setup (matches the pattern) ---
  private func reportTTExecution(execInfo : TT.ExecutionReport) : Bool {
    D.print("CANISTER: TimerTool Execution: " # debug_show (execInfo));
    false;
  };
  private func reportTTError(errInfo : TT.ErrorReport) : ?Nat {
    D.print("CANISTER: TimerTool Error: " # debug_show (errInfo));
    null;
  };
  stable var tt_migration_state : TT.State = TT.Migration.migration.initialState;
  let tt = TT.Init<system>({
    manager = initManager;
    initialState = tt_migration_state;
    args = ttInitArgs;
    pullEnvironment = ?(
      func() : TT.Environment {
        {
          advanced = null;
          reportExecution = ?reportTTExecution;
          reportError = ?reportTTError;
          syncUnsafe = null;
          reportBatch = null;
        };
      }
    );
    onInitialize = null;
    onStorageChange = func(state : TT.State) { tt_migration_state := state };
  });

  // --- Logger Setup (matches the pattern) ---
  stable var localLog_migration_state : Log.State = Log.initialState();
  let localLog = Log.Init<system>({
    args = ?{ min_level = ?#Debug; bufferSize = ?5000 };
    manager = initManager;
    initialState = localLog_migration_state;
    pullEnvironment = ?(
      func() : Log.Environment {
        { tt = tt(); advanced = null; onEvict = null };
      }
    );
    onInitialize = null;
    onStorageChange = func(state : Log.State) {
      localLog_migration_state := state;
    };
  });

  // --- ICRC3 Integration ---
  stable let cert_store : CertTree.Store = CertTree.newStore();
  let ct = CertTree.Ops(cert_store);

  private func get_certificate_store() : CertTree.Store {
    cert_store;
  };

  private func updated_certification(cert : Blob, lastIndex : Nat) : Bool {
    ct.setCertifiedData();
    true;
  };

  private func get_icrc3_environment() : ICRC3.Environment {
    {
      updated_certification = ?updated_certification;
      get_certificate_store = ?get_certificate_store;
    };
  };

  stable var icrc3_migration_state = ICRC3.initialState();
  let icrc3 = ICRC3.Init<system>({
    manager = initManager;
    initialState = icrc3_migration_state;
    args = null; // Optionally add ICRC3.InitArgs if needed
    pullEnvironment = ?get_icrc3_environment;
    onInitialize = ?(
      func(newClass : ICRC3.ICRC3) : async* () {
        if (newClass.stats().supportedBlocks.size() == 0) {
          newClass.update_supported_blocks([
            { block_type = "uupdate_user"; url = "https://git.com/user" },
            { block_type = "uupdate_role"; url = "https://git.com/user" },
            { block_type = "uupdate_use_role"; url = "https://git.com/user" },
          ]);
        };
      }
    );
    onStorageChange = func(state : ICRC3.State) {
      icrc3_migration_state := state;
    };
  });

  // --- ICRC-127 Library Setup (The Core of this Canister) ---
  stable var icrc127_migration_state : ICRC127.State = ICRC127.initialState();
  let icrc127 = ICRC127.Init<system>({
    manager = initManager;
    initialState = icrc127_migration_state;
    args = icrc127InitArgs;
    pullEnvironment = ?(
      func() : ICRC127.Environment {
        {
          tt = tt();
          advanced = null;
          log = localLog();
          add_record = ?(
            func<system>(data : ICRC127.ICRC16, meta : ?ICRC127.ICRC16) : Nat {
              let converted_data = convertIcrc127ValueToIcrc3Value(data);
              let converted_meta = Option.map(meta, convertIcrc127ValueToIcrc3Value);
              icrc3().add_record<system>(converted_data, converted_meta);
            }
          );

          // --- Provide token transfer hooks to the library ---
          icrc1_transfer = func(canister : Principal, args : ICRC2.TransferArgs) : async ICRC2.TransferResult {
            let from_balance = Option.get(Map.get(balances, Map.phash, thisPrincipal), 0);
            if (from_balance < args.amount) {
              return #Err(#InsufficientFunds({ balance = from_balance }));
            };

            Map.set(balances, Map.phash, thisPrincipal, from_balance - args.amount);
            let to_balance = Option.get(Map.get(balances, Map.phash, args.to.owner), 0);
            Map.set(balances, Map.phash, args.to.owner, to_balance + args.amount);

            return #Ok(1); // Dummy trx id
          };

          icrc2_transfer_from = func(canister : Principal, args : ICRC2.TransferFromArgs) : async ICRC2.TransferFromResult {
            let spender_allowances = Option.get(Map.get(allowances, Map.phash, args.from.owner), Map.new<Principal, Nat>());
            let allowance = Option.get(Map.get(spender_allowances, Map.phash, thisPrincipal), 0);
            if (allowance < args.amount) {
              return #Err(#InsufficientAllowance({ allowance = allowance }));
            };

            let from_balance = Option.get(Map.get(balances, Map.phash, args.from.owner), 0);
            if (from_balance < args.amount) {
              return #Err(#InsufficientFunds({ balance = from_balance }));
            };

            Map.set(spender_allowances, Map.phash, thisPrincipal, allowance - args.amount);
            Map.set(balances, Map.phash, args.from.owner, from_balance - args.amount);
            let to_balance = Option.get(Map.get(balances, Map.phash, args.to.owner), 0);
            Map.set(balances, Map.phash, args.to.owner, to_balance + args.amount);

            return #Ok(1); // Dummy trx id
          };

          validate_submission = func(req : Service.RunBountyRequest) : async Service.RunBountyResult {
            // This is our simple mock logic for the test canister.
            // A real host will have more complex logic here.
            if (req.submission == req.challenge_parameters) {
              {
                result = #Valid;
                metadata = #Map([("icrc127:submission_status", #Text("valid"))]);
                trx_id = null;
              };
            } else {
              {
                result = #Invalid;
                metadata = #Map([("icrc127:submission_status", #Text("invalid"))]);
                trx_id = null;
              };
            };
          };
        };
      }
    );
    onStorageChange = func(state) { icrc127_migration_state := state };
    onInitialize = null;
  });

  // --- Public API Implementation ---
  public shared (msg) func icrc127_create_bounty(req : Service.CreateBountyRequest) : async Service.CreateBountyResult {
    await icrc127().icrc127_create_bounty<system>(msg.caller, req);
  };
  public shared (msg) func icrc127_submit_bounty(req : Service.BountySubmissionRequest) : async Service.BountySubmissionResult {
    await icrc127().icrc127_submit_bounty(msg.caller, req);
  };
  public query func icrc127_get_bounty(bounty_id : Nat) : async ?ICRC127.Bounty {
    icrc127().icrc127_get_bounty(bounty_id);
  };
  public query func icrc127_list_bounties(filter : ?[Service.ListBountiesFilter], prev : ?Nat, take : ?Nat) : async [ICRC127.Bounty] {
    icrc127().icrc127_list_bounties(filter, prev, take);
  };
  public query func icrc127_metadata() : async ICRC127.ICRC16Map {
    icrc127().icrc127_metadata();
  };
  public query func icrc10_supported_standards() : async [{
    name : Text;
    url : Text;
  }] {
    icrc127().icrc10_supported_standards();
  };

  // --- ICRC3 Endpoints ---
  public query func icrc3_get_blocks(args : ICRC3.GetBlocksArgs) : async ICRC3.GetBlocksResult {
    icrc3().get_blocks(args);
  };
  public query func icrc3_get_archives(args : ICRC3.GetArchivesArgs) : async ICRC3.GetArchivesResult {
    icrc3().get_archives(args);
  };
  public query func icrc3_supported_block_types() : async [ICRC3.BlockType] {
    icrc3().supported_block_types();
  };
  public query func icrc3_get_tip_certificate() : async ?ICRC3.DataCertificate {
    icrc3().get_tip_certificate();
  };
  public query func get_tip() : async ICRC3.Tip {
    icrc3().get_tip();
  };

  // --- Helper functions for tests ---
  public shared (msg) func mint(to : Principal, amount : Nat) : async () {
    let balance = Option.get(Map.get(balances, Map.phash, to), 0);
    Map.set(balances, Map.phash, to, balance + amount);
  };
  public shared (msg) func approve(spender : Principal, amount : Nat) : async () {
    let spender_allowances = Option.get(Map.get(allowances, Map.phash, msg.caller), Map.new<Principal, Nat>());
    Map.set(spender_allowances, Map.phash, spender, amount);
    Map.set(allowances, Map.phash, msg.caller, spender_allowances);
  };
  public query func get_balance(of : Principal) : async Nat {
    Option.get(Map.get(balances, Map.phash, of), 0);
  };
};
