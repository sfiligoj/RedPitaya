////////////////////////////////////////////////////////////////////////////////
// Arbitrary signal generator. Holds table and FSM for one channel.
// Author: Matej Oblak, Iztok Jeras
// (c) Red Pitaya  http://www.redpitaya.com
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
//
// GENERAL DESCRIPTION:
//
// Arbitrary signal generator takes data stored in buffer and sends them to DAC.
//
//
//                /-----\
//   SW --------> | BUF | ---> output
//          |     \-----/
//          |        ^
//          |        |
//          |     /-----\
//          ----> |     |
//                | FSM | ---> trigger notification
//   trigger ---> |     |
//                \-----/
//
//
// Submodule for ASG which hold buffer data and control registers for one channel.
//
////////////////////////////////////////////////////////////////////////////////
//
// PERIODIC MODE (FREQUENCY/PHASE AND RESOLUTION
// 
// The frequency is specified by the cfg_ste value, the phase by the cfg_off
// value and both also depend on the buffer length cfg_siz. The cfg_ste (step
// length) and cfg_off (initial position) values are fixed point with a
// magnitude of CWM bits and a fraction of CWF bits.
//
// The buffer is usually programmed to contain a full period of the desired
// waveform, and the whole available buffer is usually used since it provides
// the best resolution. The buffer length is defined as (cfg_siz+1) and can be
// at most 2**CWM locations when:
// cfg_off = 2**CWF - 1
//
// The frequency and phase resolutions are defined by the smaller values of
// control variables.
//
// Frequency:
// f = Fs/(cfg_siz+1) * (cfg_ste+1)/(2**CWF)
//
// Frequency (max bufer size):
// f = Fs/(2**(CWM+CWF)) * (cfg_ste+1)
//
// Phase:
// Φ = 360°/(cfg_siz+1) * (cfg_off+1)/(2**CWF)
//
// Phase (max bufer size):
// Φ = 360°/(2**(CWM+CWF)) * (cfg_off+1)
//
// Resolution:
// Δf = Fs  /2**(CWM+CWF)
// ΔΦ = 360°/2**(CWM+CWF)
//
// Example values:
// The default fixed point format for cfg_ste and cfg_off is u14.16 and the
// default buffer size is 2**14=16384 locations.
// Fs = 125MHz
// Δf = 125MHz/2**(14+16) = 0.116Hz
// ΔΦ = 360°  /2**(14+16) = 0.000000335°
//
////////////////////////////////////////////////////////////////////////////////
//
// BURST MODE
//
// Burst mode is enabled using the cfg_ben signal.
// In the next diagram 'D' is date read from the buffer, while I is idle data
// (repetition of last value read from the buffer). The D*I* sequence can be
// repeated. Each sample from the table is repeated (cfg_bdr+1) times.
// (cfg_bdl+1) samples are read from the table.
//
// DDDDDDDDIIIIIIIIDDDDDDDDIIIIIIIIDDDDDDDDIIIIIIII...
//                                                     cfg_bdr+1 data repetitions
// |<---->|        |<---->|        |<---->|            cfg_bdl+1 data length
// |<------------>||<------------>||<------------>|    cfg_bpl+1 period length
//                                                     cfg_bpn+1 period number
//
////////////////////////////////////////////////////////////////////////////////

module asg #(
  // data bus
  int unsigned DN = 1,
  type DT = logic [8-1:0],
  // continuous/periodic buffer parameters
  int unsigned CWM = 14,  // counter width magnitude (fixed point integer)
  int unsigned CWF = 16,  // counter width fraction  (fixed point fraction)
  // burst counter parameters
  int unsigned CWR = 14,  // counter width repetitions
  int unsigned CWL = 32,  // counter width length
  int unsigned CWN = 16   // counter width number
)(
  // stream output
  axi4_stream_if.s           sto    ,
  // control
  input  logic               ctl_rst,  // set FSM to reset
  // control/status acquire
  input  logic               ctl_str,
  output logic               sts_str,
  // control/status stop
  input  logic               ctl_stp,
  output logic               sts_stp,
  // control/status trigger
  input  logic               ctl_trg,
  output logic               sts_trg,
  // events
  output logic               evn_per,  // period
  output logic               evn_lst,  // last
  // generator mode
  input  logic               cfg_ben,  // burst enable
  input  logic               cfg_inf,  // infinite
  // continuous/periodic configuration
  input  logic [CWM+CWF-1:0] cfg_siz,  // data table size
  input  logic [CWM+CWF-1:0] cfg_ste,  // pointer step    size
  input  logic [CWM+CWF-1:0] cfg_off,  // pointer initial offset (used to define phase)
  // burst configuration (burst mode)
  input  logic     [CWR-1:0] cfg_bdr,  // burst data   repetitions
  input  logic     [CWM-1:0] cfg_bdl,  // burst data   length
  input  logic     [CWL-1:0] cfg_bpl,  // burst period length
  input  logic     [CWN-1:0] cfg_bpn,  // burst period number
  // status
  output logic     [CWL-1:0] sts_bpl,  // burst period length counter
  output logic     [CWN-1:0] sts_bpn,  // burst period number counter
  // System bus
  sys_bus_if.s               bus
);

////////////////////////////////////////////////////////////////////////////////
// local signals
////////////////////////////////////////////////////////////////////////////////

// buffer
DT                  buf_mem [0:2**CWM-1];
DT    [2      -1:0] buf_rdata;            // read data
logic [CWM    -1:0] buf_raddr;            // read address
logic [CWM    -1:0] buf_ptr;              // read pointer
logic [2      -1:0] buf_adr_vld;          // valid (read data enable)
logic [2      -1:0] buf_adr_lst;          // last

// bus
// additional register added to optimize timing
DT                  bus_rdata;   // read data
logic               bus_ren;     // read enable 

// continuous/periodic pointers
logic [CWM+CWF-1:0] ptr_cur; // current
logic [CWM+CWF-0:0] ptr_nxt; // next
logic [CWM+CWF-0:0] ptr_nxt_sub ;
logic               ptr_nxt_sub_neg;
// burst counters/status
logic     [CWR-1:0] sts_bdr;  // burst data   repetitions
logic     [CWM-1:0] sts_bdl;  // burst data   length
logic               end_bdr;  // burst data   repetitions
logic               end_bdl;  // burst data   length
logic               end_bpl;  // burst period length
logic               end_bpn;  // burst period number
// address enable
logic               sts_adr;      // address enable
logic               sts_adr_per;  // address enable periodic engine
logic               sts_adr_bst;  // address enable burst    engine
// backpressure (TODO: it is not implemented properly)
logic               sts_rdy;      // ready
// events
logic               ctl_run;      // run start event
logic               ctl_end;      // run end event
logic               ctl_end_per;  // run end event periodic engine
logic               ctl_end_bst;  // run end event burst    engine

////////////////////////////////////////////////////////////////////////////////
// table RAM CPU access
////////////////////////////////////////////////////////////////////////////////

logic bus_ena;
assign bus_ena = bus.wen | bus_ren;

// CPU read/write access
always_ff @(posedge bus.clk)
begin
  bus_rdata <= buf_mem [bus.addr[2+:CWM]];
  if (bus_ren) bus.rdata <= bus_rdata ;
  if (bus.wen)  buf_mem [bus.addr[2+:CWM]] <= bus.wdata;
end
// TODO: asymetric bus width is failing synthesis
//for (int unsigned i=0; i<2; i++) begin
//  if (bus_ena) begin
//                  bus.rdata [16*i+:16] <= buf_mem [{bus.addr[2+:CWM-1],i[0]}];
//    if (bus.wen)  buf_mem [{bus.addr[2+:CWM-1],i[0]}] <= bus.wdata [16*i+:16];
//  end
//end

always_ff @(posedge bus.clk)
bus_ren <= bus.ren;

// CPU control signals
always_ff @(posedge bus.clk)
if (~bus.rstn)  bus.ack <= 1'b0;
else            bus.ack <= bus_ena;

assign bus.err = 1'b0;

////////////////////////////////////////////////////////////////////////////////
// table RAM stream read
////////////////////////////////////////////////////////////////////////////////

// stream read data
always_ff @(posedge sto.ACLK)
begin
   buf_rdata[0] <= buf_mem[buf_raddr];
  if (buf_adr_vld[1]) buf_rdata[1] <= buf_rdata[0] ;
end

// stream read pointer
always_ff @(posedge sto.ACLK)
if (sts_adr)  buf_raddr <= buf_ptr;

// valid signal used to enable memory read access
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  buf_adr_vld <= 2'b0;
  buf_adr_lst <= 2'b0;
end else begin
  if (ctl_rst) begin
    buf_adr_vld <= 2'b0;
    buf_adr_lst <= 2'b0;
  end else begin
    buf_adr_vld[1] <= buf_adr_vld[0];
    buf_adr_lst[1] <= buf_adr_lst[0];
    if (sts_rdy) begin
      buf_adr_vld[0] <= sts_trg;
      buf_adr_lst[0] <= sts_trg && ctl_end;
    end
  end
end

// address status depends on burst mode
assign sts_adr = cfg_ben ? sts_adr_bst : sts_adr_per;

// buffer pointer depends on burst mode
assign buf_ptr = cfg_ben ? sts_bdl : ptr_cur[CWF+:CWM];

////////////////////////////////////////////////////////////////////////////////
// start/stop status
////////////////////////////////////////////////////////////////////////////////

// start status
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  sts_str <= 1'b0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    sts_str <= 1'b0;
  end else begin
    // start stop control signals
    if      (ctl_stp)  sts_str <= 1'b0;
    else if (ctl_str)  sts_str <= 1'b1;
  end
end

// stop status
assign sts_stp = ~sts_str;

// control run (trigger while started or simultaneous trigger and start)
assign ctl_run = ctl_trg & (sts_str | ctl_str);

// control end depends on burst mode
assign ctl_end = cfg_ben ? ctl_end_bst : ctl_end_per;

// trigger status
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  sts_trg <= 1'b0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    sts_trg <= 1'b0;
  end else begin
    if      (ctl_end)  sts_trg <= 1'b0;
    else if (ctl_run)  sts_trg <= 1'b1;
  end
end

////////////////////////////////////////////////////////////////////////////////
// continuous/periodic mode state machine
////////////////////////////////////////////////////////////////////////////////

// control end event
// the only way to stop continuous/periodic mode is with a stop event
assign ctl_end_per = ctl_stp;

// TODO: it might not be necessary to read data all the time
// optimizing it would slightly reduce power consumption
assign sts_adr_per = sts_trg;

// address pointer counter
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  ptr_cur <= '0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    ptr_cur <= '0;
  end else if (~cfg_ben) begin
    // start on trigger, new triggers are ignored while ASG is running
    if                (ctl_run)  ptr_cur <= cfg_off;
    // modulo (proper wrapping) increment pointer
    else if (sts_trg & sts_rdy)  ptr_cur <= ~ptr_nxt_sub_neg ? ptr_nxt_sub : ptr_nxt;
  end
end

// next pointer value and overflow
assign ptr_nxt     = ptr_cur + (cfg_ste + 1);
assign ptr_nxt_sub = ptr_nxt - (cfg_siz + 1);
assign ptr_nxt_sub_neg = ptr_nxt_sub[CWM+CWF];

////////////////////////////////////////////////////////////////////////////////
// burst mode state machine
////////////////////////////////////////////////////////////////////////////////

// control end event
assign ctl_end_bst = ctl_stp | (end_bpl & end_bpn); 

// state machine
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  sts_adr_bst <= 1'b0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    sts_adr_bst <= 1'b0;
  end else if (cfg_ben) begin
    // address enable status
    if      (ctl_end)  sts_adr_bst <= 1'b0;
    else if (ctl_run)  sts_adr_bst <= 1'b1;
    else if (sts_trg & sts_rdy) begin
      if      (end_bpl)  sts_adr_bst <= 1'b1;
      else if (end_bdl)  sts_adr_bst <= 1'b0;
    end
  end
end

// address pointer counter
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  sts_bdr <= '0;
  sts_bdl <= '0;
  sts_bpl <= '0;
  sts_bpn <= '0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    sts_bdr <= '0;
    sts_bdl <= '0;
    sts_bpl <= '0;
    sts_bpn <= '0;
  end else if (cfg_ben) begin
    if (ctl_run) begin
      sts_bdr <= '0;
      sts_bdl <= '0;
      sts_bpl <= '0;
      sts_bpn <= '0;
    end else if (sts_trg & sts_rdy) begin
      sts_bdr <= end_bdr ? 0 : sts_bdr + !end_bdl;
      sts_bdl <= end_bpl ? 0 : sts_bdl +  end_bdr;
      sts_bpl <= end_bpl ? 0 : sts_bpl +        1; 
      sts_bpn <=               sts_bpn +  end_bpl;
    end
  end
end

// counter end status
assign end_bdr = (sts_bdr == cfg_bdr);
assign end_bdl = (sts_bdl == cfg_bdl) & end_bdr;
assign end_bpl = (sts_bpl == cfg_bpl);
assign end_bpn = (sts_bpn == cfg_bpn) & ~cfg_inf;

// events
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn)  evn_per <= 1'b0;
else               evn_per <= cfg_ben & sts_trg & end_bpl;

assign evn_lst = buf_adr_lst[1];

////////////////////////////////////////////////////////////////////////////////
// output stream
////////////////////////////////////////////////////////////////////////////////

// output data
assign sto.TDATA = buf_rdata[1];

// output keep/last
always_ff @(posedge sto.ACLK)
if (sts_rdy) begin
  sto.TKEEP <= '1;
  sto.TLAST <= buf_adr_lst[1];
end

// output valid
always_ff @(posedge sto.ACLK)
if (~sto.ARESETn) begin
  sto.TVALID <= 1'b0;
end else begin
  // synchronous clear
  if (ctl_rst) begin
    sto.TVALID <= 1'b0;
  end else if (sts_rdy) begin
    sto.TVALID <= buf_adr_vld[1];
  end
end

assign sts_rdy = sto.TREADY | ~sto.TVALID;

endmodule: asg
