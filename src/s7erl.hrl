%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Aug 2022 11:49
%%% links to resources about the protocol
%%% https://www.tanindustrie.de/fr/Help/ConfigClient/tsap_s7.htm
%%% https://github.com/mushorg/conpot/blob/master/conpot/protocols/s7comm/cotp.py
%%% https://javamana.com/2022/137/202205170826321818.html
%%% https://plc4x.apache.org/protocols/s7/index.html
%%% http://gmiru.com/article/s7comm-part2/
%%% http://www.bj-ig.de/service/verfuegbare-dokumentationen/s7-kommunikation/s7-kommunikationsbeispiel/index.html
%%% https://github.com/automayt/ICS-pcap/tree/master/S7
%%% https://github.com/bartei/pysiemens
%%% https://github.com/robinson/gos7
%%%-------------------------------------------------------------------
-author("heyoka").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% TPKT Header
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-define(TPKT_HEADER_LENGTH, 4).

%% 0 -> Version (0x03),
%% 1 -> Reserved (0x00),
%% 2-3 -> Length (0x0016)

-define(TPKT_VERSION, 16#03).
-define(TPKT_LENGTH, 16#0016).

-define(TPKT_HEADER, <<?TPKT_VERSION, 16#00, ?TPKT_LENGTH:16>>).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% COTP Structure
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-define(COTP_CONNECT_LENGTH, 17). %% not including the length field itself

%% COTP There are two kinds , Connected COTP And data COTP


%%% COTP Connect 18 bytes

%% 0 - 1 -> Length (not including this field) (0x11)

%% 1 - 1 -> PDU type （CRConnect Request Connection request ）
%%          0xE0, Connection request
%%          0xD0, Connect to confirm
%%          0x80, Disconnect request
%%          0xC0, Disconnect confirmation
%%          0x50, Refuse
%%          0xf0, data

%% 2-3 - 2 -> Target reference , Used to uniquely identify the target (0x10)
%% 4-5 - 2 -> Source reference
%% 6 - 1 -> Class front 4 position extended formats Last but not least 2 position ...
%% 7 - 1 -> Parameter code：tpdu-size (0xC0)
%% 8 - 1 -> Parameter length
%% 9 - 1 -> TPDU size (0x0A)
%% 10 - 1 -> Parameter code: src-tsap (0xC1)
%% 11 - 1 -> Parameter length (0x02)
%% 12-13 - 2 -> SourceTSAP/Rack (0x0201)
%% 14 - 1 -> Parameter code: dst-tsap
%% 15 - 1 -> Parameter length
%% 16-17 - 2 -> DestinationTSAP / Slot (0x0201)

-define(COTP_HEADER_PDU_TYPE_CONN_REQ, 16#e0).
-define(COTP_HEADER_PDU_TYPE_CONN_CONFIRM, 16#d0).
-define(COTP_HEADER_PDU_TYPE_DISCONN_REQ, 16#80).
-define(COTP_HEADER_PDU_TYPE_DISCONN_CONFIRM, 16#c0).
%%-define(COTP_HEADER_PDU_TYPE_REFUSE, 16#50).
-define(COTP_HEADER_PDU_TYPE_DATA, 16#f0).

-define(COTP_HEADER_PDU_PARAM_CODE_TPDUSIZE, 16#c0).
-define(COTP_HEADER_PDU_TPDUSIZE, 16#0a).
-define(COTP_HEADER_PDU_PARAM_CODE_SRC_TSAP, 16#c1).
-define(COTP_HEADER_PDU_PARAM_CODE_DEST_TSAP, 16#c2).
-define(COTP_HEADER_PDU_PARAM_LENGTH, 2).

-define(LOCAL_TSAP, 16#0100).

-define(COTP_DATA_LENGTH, 3).

%%% COTP Data 3 bytes

%% 0 - 1 -> Length, not including this field (0x11)

%% 1 - 1 -> PDU type （CRConnect Request Connection request ）
%%          0x0e, Connection request
%%          0x0d, Connect to confirm
%%          0x08, Disconnect request
%%          0x0c, Disconnect confirmation
%%          0x05, Refuse

%% 2 - 1 -> Destination reference First place ： Whether the last data after 7 position ： TPDU** Number

%%-define(COTP_PDU_TYPE_CONN_REQ, 16#0e).
%%-define(COTP_PDU_TYPE_CONN_CONFIRM, 16#0d).
%%-define(COTP_PDU_TYPE_DISCONN_REQ, 16#08).
%%-define(COTP_PDU_TYPE_DISCONN_CONFIRM, 16#0c).
%%-define(COTP_PDU_TYPE_REFUSE, 16#05).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% S7 PDU Structure
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-define(S7PDU_MAX_REF_ID, 16#ffff).

%% Header - Parameters - Data

%% Header -> Contains length information ,PDU Reference and message type constants
%% Parameters -> The content and structure are based on PDU There are great differences between the types of messages and functions
%% Data -> The data is an optional field to carry the data , For example, memory value , Block code , Firmware data, etc .

-define(S7PDU_REQ_HEADER_LENGTH, 10).
%% The response message contains two additional error code bytes (Error Class, Error Code)
-define(S7PDU_RESP_HEADER_LENGTH, 12).

-define(S7PDU_PROTOCOL_ID, 16#32).
-define(S7PDU_MAX_PDUSIZE, 960).
%%%%%%%%%%%%%%%%%%%%% REQ-HEADER

%% 0 - 1 -> Protocol Id always 0x32（ Constant ）
%% 1 - 1 -> ROSCTR/MSG Type // pdu（Protocol Data Unit） The type of
%%          0x01-job
%%          0x02-ack
%%          0x03-ack-data
%%          0x07-Userdata
%% 2-3 - 2 -> Redundancy Identification (Retain)
%% 4-5 - 2 -> Protocol Data Unit Reference // |pdu The reference of – Generated by the master station , Each new transmission is incremented （ Big end ）
%% 6-7 - 2 -> Parameter length, Big endian
%% 8-9 - 2 -> Data length, Big endian

-define(S7PDU_ROSCTR_JOB,       16#01).
-define(S7PDU_ROSCTR_ACK,       16#02).
-define(S7PDU_ROSCTR_ACK_DATA,  16#03).
-define(S7PDU_ROSCTR_USERDATA,  16#07).

-define(S7PDU_FUNCTION_READ_VAR, 16#04).
-define(S7PDU_FUNCTION_WRITE_VAR, 16#05).

-define(S7_READ_VAR_TYPE_BIT, 16#01).
-define(S7_READ_VAR_TYPE_CHAR, 16#03).
-define(S7_READ_VAR_TYPE_BYTE, 16#04).

%%0x03	BIT	bit access, len is in bits
%%0x04	BYTE/WORD/DWORD	byte/word/dword access, len is in bits
%%0x05	INTEGER	integer access, len is in bits
%%0x06	DINTEGER	integer access, len is in bytes
%%0x07	REAL	real access, len is in bytes
%%0x09	OCTET STRING	octet string, len is in bytes

-define(S7_DATA_TRANSPORT_BIT, 16#03).
-define(S7_DATA_TRANSPORT_BYTE, 16#04).
-define(S7_DATA_TRANSPORT_INT, 16#05).
-define(S7_DATA_TRANSPORT_DINT, 16#06).
-define(S7_DATA_TRANSPORT_REAL, 16#07).
-define(S7_DATA_TRANSPORT_STRING, 16#09).

-define(S7PDU_FUNCTION_CODES, [
  {cpu_services, 0},
  {read_variable, 16#04},
  {write_variable, 16#05},
  {request_download, 16#1a},
  {download_block, 16#1b},
  {download_ended, 16#1c},
  {start_upload, 16#1d},
  {upload, 16#1e},
  {end_upload, 16#1f},
  {plc_control, 16#28},
  {plc_stop, 16#29},
  {setup_communication, 16#f0}
  ]).

-define(S7PDU_BLOCK_TYPES, [
  {ob, 16#38},
  {db, 16#41},
  {sdb, 16#42},
  {fc, 16#43},
  {sfc, 16#44},
  {fb, 16#45},
  {sfb, 16#46}
]).

-define(S7PDU_TRANSPORT_TYPE,
  [
    {bit, 1},
    {byte, 2},
    {char, 3},
    {word, 4},
    {int, 5},
    {d_word, 6},
    {dint, 7},
    {real, 8},
    {date, 9},
    {tod, 10},
    {time, 11},
    {counter, 16#1c}
  ]).

-define(S7PDU_AREA, [
  {inputs, 16#81},
  {outputs, 16#82},
  {flags, 16#83},
  {db, 16#84},
  {s7counters, 16#1c},
  {s7timers, 16#1d}
]).

-define(REQUEST_GET_DATETIME,
  <<
  16#03, 16#00, 16#00, 16#1d, 16#02, 16#f0, 16#80, 16#32, 16#07,
  16#00, 16#00, 16#38, 16#00, 16#00, 16#08, 16#00, 16#04, 16#00, 16#01, 16#12,
  16#04, 16#11, 16#47, 16#01, 16#00, 16#0a, 16#00, 16#00, 16#00
  >>).

-define(REQUEST_GET_PLC_STATUS,
  <<16#03, 16#00, 16#00, 16#21, 16#02, 16#f0, 16#80, 16#32, 16#07,
  16#00, 16#00, 16#2c, 16#00, 16#00, 16#08, 16#00, 16#08, 16#00, 16#01, 16#12,
  16#04, 16#11, 16#44, 16#01, 16#00, 16#ff, 16#09, 16#00, 16#04, 16#04, 16#24,
  16#00, 16#00 
  >>).


-define(DATA_ITEM_ERRORS, [
  {0, <<"reserved">>},
  {1, <<"hardware error">>},
  {3, <<"access not allowed">>},
  {5, <<"invalid address">>},
  {7, <<"data type inconsistent">>},
  {16#0a, <<"object does not exist">>},
  {16#ff, <<"success">>}
  ]).

-define(ERROR_CLASSES, [
  {16#00, <<"no error">>},
  {16#81, <<"application relationship error">>},
  {16#82, <<"object definition error">>},
  {16#83, <<"no resources available">>},
  {16#84, <<"error on service processing">>},
  {16#85, <<"error on supplies">>},
  {16#87, <<"access error">>}
  ]).

-define(ERROR_CODES, [
  {0, <<"No error">>},
  {272, <<"Invalid block number">>},
  {273, <<"Invalid request length">>},
  {274, <<"Invalid parameter">>},
  {275, <<"Invalid block type">>},
  {276, <<"Block not found">>},
  {277, <<"Block already exists">>},
  {278, <<"Block is write-protected">>},
  {279, <<"The block/operating system update is too large">>},
  {280, <<"Invalid block number">>},
  {281, <<"Incorrect password entered">>},
  {282, <<"PG resource error">>},
  {283, <<"PLC resource error">>},
  {284, <<"Protocol error">>},
  {285, <<"Too many blocks (module-related restriction)">>},
  {286, <<"There is no longer a connection to the database, or S7DOS handle is invalid">>},
  {287, <<"Result buffer too small">>},
  {288, <<"End of block list">>},
  {320, <<"Insufficient memory available">>},
  {321, <<"Job cannot be processed because of a lack of resources">>},
  {32768, <<"Function already occupied">>},
  {32769, <<"The requested service cannot be performed while the block is in the current status">>},
  {32771, <<"S7 protocol error: Error occurred while transferring the block">>},
  {33024, <<"Application, general error: Service unknown to remote module">>},
  {33025, <<"Hardware fault">>},
  {33027, <<"Object access not allowed">>},
  {33028, <<"This service is not implemented on the module or a frame error was reported">>},
  {33029, <<"Invalid address">>},
  {33030, <<"Data type not supported">>},
  {33031, <<"Data type not consistent">>},
  {33034, <<"Object does not exist">>},
  {33284, <<"The type specification for the object is inconsistent">>},
  {33285, <<"A copied block already exists and is not linked">>},
  {33537, <<"Insufficient memory space or work memory on the module, or specified storage medium not accessible">>},
  {33538, <<"Too few resources available or the processor resources are not available">>},
  {33540, <<"No further parallel upload possible. There is a resource bottleneck">>},
  {33541, <<"Function not available">>},
  {33542, <<"Insufficient work memory (for copying, linking, loading AWP)">>},
  {33543, <<"Not enough retentive work memory (for copying, linking, loading AWP)">>},
  {33793, <<"S7 protocol error: Invalid service sequence (for example, loading or uploading a block)">>},
  {33794, <<"Service cannot execute owing to status of the addressed object">>},
  {33796, <<"S7 protocol: The function cannot be performed">>},
  {33797, <<"Remote block is in DISABLE state (CFB). The function cannot be performed">>},
  {34048, <<"S7 protocol error: Wrong frames">>},
  {34051, <<"Alarm from the module: Service canceled prematurely">>},
  {34561, <<"Error addressing the object on the communications partner (for example, area length error)">>},
  {34562, <<"The requested service is not supported by the module">>},
  {34563, <<"Access to object refused">>},
  {34564, <<"Access error: Object damaged">>},
  {53249, <<"Protocol error: Illegal job number">>},
  {53250, <<"Parameter error: Illegal job variant">>},
  {53251, <<"Parameter error: Debugging function not supported by module">>},
  {53252, <<"Parameter error: Illegal job status">>},
  {53253, <<"Parameter error: Illegal job termination">>},
  {53254, <<"Parameter error: Illegal link disconnection ID">>},
  {53255, <<"Parameter error: Illegal number of buffer elements">>},
  {53256, <<"Parameter error: Illegal scan rate">>},
  {53257, <<"Parameter error: Illegal number of executions">>},
  {53258, <<"Parameter error: Illegal trigger event">>},
  {53259, <<"Parameter error: Illegal trigger condition">>},
  {53265, <<"Parameter error in path of the call environment: Block does not exist">>},
  {53266, <<"Parameter error: Wrong address in block">>},
  {53268, <<"Parameter error: Block being deleted/overwritten">>},
  {53269, <<"Parameter error: Illegal tag address">>},
  {53270, <<"Parameter error: Test jobs not possible, because of errors in user program">>},
  {53271, <<"Parameter error: Illegal trigger number">>},
  {53285, <<"Parameter error: Invalid path">>},
  {53286, <<"Parameter error: Illegal access type">>},
  {53287, <<"Parameter error: This number of data blocks is not permitted">>},
  {53297, <<"Internal protocol error">>},
  {53298, <<"Parameter error: Wrong result buffer length">>},
  {53299, <<"Protocol error: Wrong job length">>},
  {53311, <<"Coding error: Error in parameter section (for example, reserve bytes not equal to 0)">>},
  {53313, <<"Data error: Illegal status list ID">>},
  {53314, <<"Data error: Illegal tag address">>},
  {53315, <<"Data error: Referenced job not found, check job data">>},
  {53316, <<"Data error: Illegal tag value, check job data">>},
  {53317, <<"Data error: Exiting the ODIS control is not allowed in HOLD">>},
  {53318, <<"Data error: Illegal measuring stage during run-time measurement">>},
  {53319, <<"Data error: Illegal hierarchy in 'Read job list'">>},
  {53320, <<"Data error: Illegal deletion ID in 'Delete job'">>},
  {53321, <<"Invalid substitute ID in 'Replace job'">>},
  {53322, <<"Error executing 'program status'">>},
  {53343, <<"Coding error: Error in data section (for example, reserve bytes not equal to 0, ...)">>},
  {53345, <<"Resource error: No memory space for job">>},
  {53346, <<"Resource error: Job list full">>},
  {53347, <<"Resource error: Trigger event occupied">>},
  {53348, <<"Resource error: Not enough memory space for one result buffer element">>},
  {53349, <<"Resource error: Not enough memory space for several  result buffer elements">>},
  {53350, <<"Resource error: The timer available for run-time measurement is occupied by another job">>},
  {53351, <<"Resource error: Too many 'modify tag' jobs active (in particular multi-processor operation)">>},
  {53377, <<"Function not permitted in current mode">>},
  {53378, <<"Mode error: Cannot exit HOLD mode">>},
  {53409, <<"Function not permitted in current protection level">>},
  {53410, <<"Function not possible at present, because a function is running that modifies memory">>},
  {53411, <<"Too many 'modify tag' jobs active on the I/O (in particular multi-processor operation)">>},
  {53412, <<"'Forcing' has already been established">>},
  {53413, <<"Referenced job not found">>},
  {53414, <<"Job cannot be disabled/enabled">>},
  {53415, <<"Job cannot be deleted, for example because it is currently being read">>},
  {53416, <<"Job cannot be replaced, for example because it is currently being read or deleted">>},
  {53417, <<"Job cannot be read, for example because it is currently being deleted">>},
  {53418, <<"Time limit exceeded in processing operation">>},
  {53419, <<"Invalid job parameters in process operation">>},
  {53420, <<"Invalid job data in process operation">>},
  {53421, <<"Operating mode already set">>},
  {53422, <<"The job was set up over a different connection and can only be handled over this connection">>},
  {53441, <<"At least one error has been detected while accessing the tag(s)">>},
  {53442, <<"Change to STOP/HOLD mode">>},
  {53443, <<"At least one error was detected while accessing the tag(s). Mode change to STOP/HOLD">>},
  {53444, <<"Timeout during run-time measurement">>},
  {53445, <<"Display of block stack inconsistent, because blocks were deleted/reloaded">>},
  {53446, <<"Job was automatically deleted as the jobs it referenced have been deleted">>},
  {53447, <<"The job was automatically deleted because STOP mode was exited">>},
  {53448, <<"'Block status' aborted because of inconsistencies between test job and running program">>},
  {53449, <<"Exit the status area by resetting OB90">>},
  {53450, <<"Exiting the status range by resetting OB90 and access error reading tags before exiting">>},
  {53451, <<"The output disable for the peripheral outputs has been activated again">>},
  {53452, <<"The amount of data for the debugging functions is restricted by the time limit">>},
  {53761, <<"Syntax error in block name">>},
  {53762, <<"Syntax error in function parameters">>},
  {53763, <<"Syntax error in block type">>},
  {53764, <<"No linked block in storage medium">>},
  {53765, <<"Linked block already exists in RAM: Conditional copying is not possible">>},
  {53766, <<"Linked block already exists in EPROM: Conditional copying is not possible">>},
  {53767, <<"Block exists in EPROM">>},
  {53768, <<"Maximum number of copied (not linked) blocks on module exceeded">>},
  {53769, <<"(At least) one of the given blocks not found on the module">>},
  {53770, <<"The maximum number of blocks that can be linked with one job was exceeded">>},
  {53771, <<"The maximum number of blocks that can be deleted with one job was exceeded">>},
  {53772, <<"OB cannot be copied because the associated priority class does not exist">>},
  {53773, <<"SDB cannot be interpreted (for example, unknown number)">>},
  {53774, <<"No (further) block available">>},
  {53775, <<"Module-specific maximum block size exceeded">>},
  {53776, <<"Invalid block number">>},
  {53778, <<"Incorrect header attribute (run-time relevant)">>},
  {53779, <<"Too many SDBs. Note the restrictions on the module being used">>},
  {53782, <<"Invalid user program - reset module">>},
  {53783, <<"Protection level specified in module properties not permitted">>},
  {53784, <<"Incorrect attribute (active/passive)">>},
  {53785, <<"Incorrect block lengths (for example, incorrect length of first section or of the whole block)">>},
  {53786, <<"Incorrect local data length or write-protection code faulty">>},
  {53787, <<"Module cannot compress or compression was interrupted early">>},
  {53789, <<"The volume of dynamic project data transferred is illegal">>},
  {53790, <<"Unable to assign parameters to a module (such as FM, CP). The system data could not be linked">>},
  {53792, <<"Invalid programming language. Note the restrictions on the module being used">>},
  {53793, <<"The system data for connections or routing are not valid">>},
  {53794, <<"The system data of the global data definition contain invalid parameters">>},
  {53795, <<"Error in instance data block for communication function block or maximum number of instance DBs exceeded">>},
  {53796, <<"The SCAN system data block contains invalid parameters">>},
  {53797, <<"The DP system data block contains invalid parameters">>},
  {53798, <<"A structural error occurred in a block">>},
  {53808, <<"A structural error occurred in a block">>},
  {53809, <<"At least one loaded OB cannot be copied because the associated priority class does not exist">>},
  {53810, <<"At least one block number of a loaded block is illegal">>},
  {53812, <<"Block exists twice in the specified memory medium or in the job">>},
  {53813, <<"The block contains an incorrect checksum">>},
  {53814, <<"The block does not contain a checksum">>},
  {53815, <<"You are about to load the block twice, i.e. a block with the same time stamp already exists on the CPU">>},
  {53816, <<"At least one of the blocks specified is not a DB">>},
  {53817, <<"At least one of the DBs specified is not available as a linked variant in the load memory">>},
  {53818, <<"At least one of the specified DBs is considerably different from the copied and linked variant">>},
  {53824, <<"Coordination rules violated">>},
  {53825, <<"The function is not permitted in the current protection level">>},
  {53826, <<"Protection violation while processing F blocks">>},
  {53840, <<"Update and module ID or version do not match">>},
  {53841, <<"Incorrect sequence of operating system components">>},
  {53842, <<"Checksum error">>},
  {53843, <<"No executable loader available; update only possible using a memory card">>},
  {53844, <<"Storage error in operating system">>},
  {53888, <<"Error compiling block in S7-300 CPU">>},
  {53921, <<"Another block function or a trigger on a block is active">>},
  {53922, <<"A trigger is active on a block. Complete the debugging function first">>},
  {53923, <<"The block is not active (linked), the block is occupied or the block is currently marked for deletion">>},
  {53924, <<"The block is already being processed by another block function">>},
  {53926, <<"It is not possible to save and change the user program simultaneously">>},
  {53927, <<"The block has the attribute 'unlinked' or is not processed">>},
  {53928, <<"An active debugging function is preventing parameters from being assigned to the CPU">>},
  {53929, <<"New parameters are being assigned to the CPU">>},
  {53930, <<"New parameters are currently being assigned to the modules">>},
  {53931, <<"The dynamic configuration limits are currently being changed">>},
  {53932, <<"A running active or deactivate assignment (SFC 12) is temporarily preventing R-KiR process">>},
  {53936, <<"An error occurred while configuring in RUN (CiR)">>},
  {53952, <<"The maximum number of technological objects has been exceeded">>},
  {53953, <<"The same technology data block already exists on the module">>},
  {53954, <<"Downloading the user program or downloading the hardware configuration is not possible">>},
  {54273, <<"Information function unavailable">>},
  {54274, <<"Information function unavailable">>},
  {54275, <<"Service has already been logged on/off (Diagnostics/PMC)">>},
  {54276, <<"Maximum number of nodes reached. No more logons possible for diagnostics/PMC">>},
  {54277, <<"Service not supported or syntax error in function parameters">>},
  {54278, <<"Required information currently unavailable">>},
  {54279, <<"Diagnostics error occurred">>},
  {54280, <<"Update aborted">>},
  {54281, <<"Error on DP bus">>},
  {54785, <<"Syntax error in function parameter">>},
  {54786, <<"Incorrect password entered">>},
  {54787, <<"The connection has already been legitimized">>},
  {54788, <<"The connection has already been enabled">>},
  {54789, <<"Legitimization not possible because password does not exist">>},
  {55297, <<"At least one tag address is invalid">>},
  {55298, <<"Specified job does not exist">>},
  {55299, <<"Illegal job status">>},
  {55300, <<"Illegal cycle time (illegal time base or multiple)">>},
  {55301, <<"No more cyclic read jobs can be set up">>},
  {55302, <<"The referenced job is in a state in which the requested function cannot be performed">>},
  {55303, <<"Function aborted due to overload, meaning executing the read cycle takes longer than the set scan cycle time">>},
  {56321, <<"Date and/or time invalid">>},
  {57857, <<"CPU is already the master">>},
  {57858, <<"Connect and update not possible due to different user program in flash module">>},
  {57859, <<"Connect and update not possible due to different firmware">>},
  {57860, <<"Connect and update not possible due to different memory configuration">>},
  {57861, <<"Connect/update aborted due to synchronization error">>},
  {57862, <<"Connect/update denied due to coordination violation">>},
  {61185, <<"S7 protocol error: Error at ID2; only 00H permitted in job">>},
  {61186, <<"S7 protocol error: Error at ID2; set of resources does not exist">>}
  ]).

%%%%%%%%%%%%%%%%%%%%% ACK-HEADER


%% 0 - 1 -> Protocol Id always 0x32（ Constant ）
%% 1 - 1 -> ROSCTR/MSG Type // pdu（Protocol Data Unit） The type of
%%          0x01-job
%%          0x02-ack
%%          0x03-ack-data
%%          0x07-Userdata
%% 2-3 - 2 -> Redundancy Identification (Retain)
%% 4-5 - 2 -> Protocol Data Unit Reference // |pdu The reference of – Generated by the master station , Each new transmission is incremented （ Big end ）
%% 6-7 - 2 -> Parameter length, Big endian
%% 8-9 - 2 -> Data length, Big endian
%% 10 - 1 -> Error Class
%% 11 - 1 -> Error Code




%% tcp request record
-record(tcp_request, {sock, tid = 1, address = 1, function, start, data , ts}).
