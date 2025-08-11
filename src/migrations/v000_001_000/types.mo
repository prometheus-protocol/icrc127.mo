// do not remove comments from this file
import Time "mo:base/Time";
import Principal "mo:base/Principal";
import OVSFixed "mo:ovs-fixed";
import TimerToolLib "mo:timer-tool";
import LogLib "mo:stable-local-log";
import MapLib "mo:map/Map";
import SetLib "mo:map/Set";
import BTreeLib "mo:stableheapbtreemap/BTree";
import Result "mo:base/Result";
import ICRC2 "mo:icrc2-types";

// please do not import any types from your project outside migrations folder here
// it can lead to bugs when you change those types later, because migration types should not be changed
// you should also avoid importing these types anywhere in your project directly from here
// use MigrationTypes.Current property instead

module {

  // do not remove the timer tool as it is essential for icrc85
  public let TimerTool = TimerToolLib;
  public let Log = LogLib;
  public let Map = MapLib;
  public let Set = SetLib;
  public let BTree = BTreeLib;

  public type ActionId = TimerToolLib.ActionId;
  public type Action = TimerToolLib.Action;
  public type ActionError = TimerToolLib.Error;

  //---------------------
  // Init Args (for upgrades/extensions)
  //---------------------
  public type InitArgs = {};

  //---- ICRC-16 Compatible Re-exports ----
  public type ICRC16Property = { name : Text; value : ICRC16; immutable : Bool };
  public type ICRC16 = {
    #Array : [ICRC16];
    #Blob : Blob;
    #Bool : Bool;
    #Bytes : [Nat8];
    #Class : [ICRC16Property];
    #Float : Float;
    #Floats : [Float];
    #Int : Int;
    #Int16 : Int16;
    #Int32 : Int32;
    #Int64 : Int64;
    #Int8 : Int8;
    #Map : [(Text, ICRC16)];
    #ValueMap : [(ICRC16, ICRC16)];
    #Nat : Nat;
    #Nat16 : Nat16;
    #Nat32 : Nat32;
    #Nat64 : Nat64;
    #Nat8 : Nat8;
    #Nats : [Nat];
    #Option : ?ICRC16;
    #Principal : Principal;
    #Set : [ICRC16];
    #Text : Text;
  };
  public type ICRC16Map = [(Text, ICRC16)];

  // --- ICRC-1/2 Types ---
  public type Account = { owner : Principal; subaccount : ?Blob };
  public type TransferResult = Result.Result<Nat, { #GenericError : { error_code : Nat; message : Text }; #TemporarilyUnavailable; #BadBurn : { min_burn_amount : Nat }; #Duplicate : { duplicate_of : Nat }; #BadFee : { expected_fee : Nat }; #CreatedInFuture : { ledger_time : Nat }; #TooOld; #InsufficientFunds : { balance : Nat } }>;
  public type TransferFromResult = Result.Result<Nat, { #GenericError : { error_code : Nat; message : Text }; #TemporarilyUnavailable; #InsufficientAllowance : { allowance : Nat }; #BadBurn : { min_burn_amount : Nat }; #Duplicate : { duplicate_of : Nat }; #BadFee : { expected_fee : Nat }; #CreatedInFuture : { ledger_time : Nat }; #TooOld; #InsufficientFunds : { balance : Nat } }>;

  //---------------
  // Core ICRC-127 Types
  //---------------

  public type RunBountyResult = {
    result : { #Valid; #Invalid };
    metadata : ICRC16;
    trx_id : ?Nat;
  };

  public type ClaimRecord = {
    claim_id : Nat;
    time_submitted : Nat;
    caller : Principal;
    claim_account : ?Account;
    submission : ICRC16;
    claim_metadata : ICRC16Map;
    result : ?RunBountyResult;
  };

  public type Bounty = {
    bounty_id : Nat;
    creator : Principal; // The original creator of the bounty
    token_canister_id : Principal; // The token used for the bounty
    token_amount : Nat; // The amount of the bounty
    validation_canister_id : Principal;
    validation_call_timeout : Nat;
    bounty_metadata : ICRC16Map;
    challenge_parameters : ICRC16;
    timeout_date : ?Nat;
    claimed : ?Nat;
    claims : [ClaimRecord];
    created : Nat;
    claimed_date : ?Nat;
  };

  // --- Event Types ---
  public type ICRC127EventType = {
    #bounty;
    #submit_bounty;
    #bounty_run;
    #bounty_expired;
  };

  //----------------------------------
  // ICRC127 Service State Types
  //----------------------------------

  public type ICRC85Options = OVSFixed.ICRC85Environment;

  public type RunBountyRequest = {
    bounty_id : Nat;
    submission_id : Nat;
    submission : ICRC16;
    challenge_parameters : ICRC16;
  };

  //--- Environment structure for dependency injection
  public type Environment = {
    tt : TimerToolLib.TimerTool;
    advanced : ?{
      icrc85 : ICRC85Options;
    };
    log : Log.Local_log;
    add_record : ?(<system>(ICRC16, ?ICRC16) -> Nat);
    // Functions to interact with token ledgers.
    icrc1_transfer : (canister : Principal, args : ICRC2.TransferArgs) -> async ICRC2.TransferResult;
    icrc2_transfer_from : (canister : Principal, args : ICRC2.TransferFromArgs) -> async ICRC2.TransferFromResult;

    // The host canister provides this function to perform the actual bounty validation.
    validate_submission : (req : RunBountyRequest) -> async RunBountyResult;
  };

  //--- Statistics
  public type Stats = {
    bounties_created : Nat;
    claims_submitted : Nat;
    bounties_paid : Nat;
    tt : TimerToolLib.Stats;
    icrc85 : {
      nextCycleActionId : ?Nat;
      lastActionReported : ?Nat;
      activeActions : Nat;
    };
    log : [Text];
  };

  ///MARK: State
  //--- Primary ICRC127 State
  public type State = {
    icrc85 : {
      var nextCycleActionId : ?Nat;
      var lastActionReported : ?Nat;
      var activeActions : Nat;
    };

    //-----------------
    // ICRC127 State
    //-----------------
    var bounties : BTree.BTree<Nat, Bounty>; // Map from bounty_id to Bounty record
    var next_bounty_id : Nat;

    // Maps a bounty_id to the ActionId of its scheduled expiration timer.
    // This keeps the Bounty record itself spec-compliant.
    var expiration_timers : BTree.BTree<Nat, ActionId>;
  };

  public type StateShared = {
    icrc85 : {
      nextCycleActionId : ?Nat;
      lastActionReported : ?Nat;
      activeActions : Nat;
    };

    // ICRC127 state
    bounties : [(Nat, Bounty)];
    next_bounty_id : Nat;

    expiration_timers : [(Nat, ActionId)];
  };

  public func shareState(x : State) : StateShared {
    {
      icrc85 = {
        nextCycleActionId = x.icrc85.nextCycleActionId;
        lastActionReported = x.icrc85.lastActionReported;
        activeActions = x.icrc85.activeActions;
      };

      bounties = BTree.toArray(x.bounties);
      next_bounty_id = x.next_bounty_id;

      expiration_timers = BTree.toArray(x.expiration_timers);
    };
  };
};
