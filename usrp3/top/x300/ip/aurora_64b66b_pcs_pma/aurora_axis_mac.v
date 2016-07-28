//
// Copyright 2016 Ettus Research LLC
//

module aurora_axis_mac #(
   parameter PACKET_MODE      = 0,
   parameter PACKET_FIFO_SIZE = 10,
   parameter BIST_ENABLED     = 1
) (
   // Clocks and resets
   input             phy_clk,
   input             phy_rst, 
   input             sys_clk,
   input             sys_rst, 
   // PHY TX Interface (Synchronous to phy_clk)
   output [63:0]     phy_m_axis_tdata,
   output            phy_m_axis_tvalid,
   input             phy_m_axis_tready,
   // PHY RX Interface (Synchronous to phy_clk)
   input  [63:0]     phy_s_axis_tdata,
   input             phy_s_axis_tvalid,
   // User TX Interface (Synchronous to sys_clk)
   input  [63:0]     s_axis_tdata,
   input             s_axis_tlast,
   input             s_axis_tvalid,
   output            s_axis_tready,
   // User RX Interface (Synchronous to sys_clk)
   output [63:0]     m_axis_tdata,
   output            m_axis_tlast,
   output            m_axis_tvalid,
   input             m_axis_tready,
   // PHY Status Inputs (Synchronous to phy_clk)
   input             channel_up,
   input             hard_err,
   input             soft_err,
   // Status and Error Outputs (Synchronous to sys_clk)
   output [31:0]     overruns,
   output [31:0]     soft_errors,
   output reg [31:0] checksum_errors,
   // BIST Interface (Synchronous to sys_clk)
   input             bist_gen_en,
   input  [4:0]      bist_gen_rate,
   input             bist_checker_en,
   input             bist_loopback_en,
   output reg        bist_checker_locked,
   output reg [47:0] bist_checker_samps,
   output reg [47:0] bist_checker_errors
);

   // ----------------------------------------------
   // Resets, Clears, Clock crossings
   // ----------------------------------------------

   wire phy_s_axis_tready;    // Internal only. The PHY has no backpressure signal.

   // Stay idle if the PHY is not up or if it experiences a fatal error 
   wire clear = (~channel_up) | hard_err;
   wire clear_sysclk;
   synchronizer #(.INITIAL_VAL(1'b1)) clear_sync (
      .clk(sys_clk), .rst(1'b0 /* no reset */), .in(clear), .out(clear_sysclk));

   // ----------------------------------------------
   // Counters
   // ----------------------------------------------

   reg [31:0] overruns_reg;
   reg [31:0] soft_errors_reg;

   // Counter for recoverable errors. For reporting only.
   always @(posedge phy_clk)
      if (phy_rst | clear)
         soft_errors_reg <= 32'd0;
      else if (soft_err)
         soft_errors_reg <= soft_errors_reg + 32'd1;

   // Tag an overrun if the FIFO is full. Samples will get dropped
   always @(posedge phy_clk)
      if (phy_rst | clear)
         overruns_reg <= 32'd0;
      else if (phy_s_axis_tvalid & ~phy_s_axis_tready)
         overruns_reg <= overruns_reg + 32'd1;

   wire [7:0] dummy0;
   fifo_short_2clk status_counters_2clk_i (
      .rst(phy_rst),
      .wr_clk(phy_clk), .din({8'h00, soft_errors_reg, overruns_reg}), .wr_en(1'b1), .full(), .wr_data_count(),
      .rd_clk(sys_clk), .dout({dummy0, soft_errors, overruns}), .rd_en(1'b1), .empty(), .rd_data_count()
   );

   // ----------------------------------------------
   // BIST Wires
   // ----------------------------------------------

   wire [63:0] bist_o_tdata;
   wire        bist_o_tvalid, bist_o_tready;
   wire [63:0] bist_i_tdata;
   wire        bist_i_tvalid, bist_i_tready;
   wire [63:0] loopback_tdata;
   wire        loopback_tvalid, loopback_tready;
   reg         bist_gen_en_reg = 1'b0, bist_checker_en_reg = 1'b0, bist_loopback_en_reg = 1'b0;
   reg  [4:0]  bist_gen_rate_reg = 5'b0;

   generate if (BIST_ENABLED == 1) begin
      // Pipeline control signals
      always @(posedge sys_clk) begin
         if (sys_rst | clear_sysclk) begin
            bist_gen_en_reg      <= 1'b0;
            bist_checker_en_reg  <= 1'b0;
            bist_loopback_en_reg <= 1'b0;
            bist_gen_rate_reg    <= 5'd0;
         end else begin
            bist_gen_en_reg      <= bist_gen_en;
            bist_checker_en_reg  <= bist_checker_en;
            bist_loopback_en_reg <= bist_loopback_en;
            bist_gen_rate_reg    <= bist_gen_rate;
         end
      end
   end endgenerate
   // ----------------------------------------------
   // RX Data Path
   // ----------------------------------------------

   wire [63:0]    i_raw_tdata;
   wire           i_raw_tvalid, i_raw_tready;

   wire [63:0]    i_pip_tdata;
   wire           i_pip_tvalid, i_pip_tready;

   wire [63:0]    i_pkt_tdata;
   wire           i_pkt_tlast, i_pkt_tvalid, i_pkt_tready;

   wire [63:0]    i_gt_tdata;
   wire           i_gt_tlast, i_gt_tvalid, i_gt_tready;

   wire           checksum_err;

   // Large FIFO must be able to run input side at 64b@156MHz to sustain 10Gb Rx.
   axi64_8k_2clk_fifo ingress_fifo_i (
      .s_aresetn(~phy_rst), .s_aclk(phy_clk),
      .s_axis_tdata(phy_s_axis_tdata), .s_axis_tlast(phy_s_axis_tvalid), .s_axis_tuser(4'h0),
      .s_axis_tvalid(phy_s_axis_tvalid), .s_axis_tready(phy_s_axis_tready), .axis_wr_data_count(),
      .m_aclk(sys_clk),
      .m_axis_tdata(i_raw_tdata), .m_axis_tlast(), .m_axis_tuser(),
      .m_axis_tvalid(i_raw_tvalid), .m_axis_tready(i_raw_tready), .axis_rd_data_count()
   );

   // AXI-Flop to ease timing
   axi_fifo_flop #(.WIDTH(64)) input_pipe_i0 (
      .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
      .i_tdata(i_raw_tdata), .i_tvalid(i_raw_tvalid), .i_tready(i_raw_tready),
      .o_tdata(i_pip_tdata), .o_tvalid(i_pip_tvalid),
      .o_tready(bist_checker_en_reg ? bist_i_tready : (bist_loopback_en_reg ? loopback_tready : i_pip_tready)),
      .space(), .occupied()
   );

   assign bist_i_tdata     = i_pip_tdata;
   assign bist_i_tvalid    = i_pip_tvalid & bist_checker_en_reg;

   assign loopback_tdata   = i_pip_tdata;
   assign loopback_tvalid  = i_pip_tvalid & bist_loopback_en_reg;

   // Tag stream with the tlast escape sequence
   axi_extract_tlast #(.WIDTH(64), .VALIDATE_CHECKSUM(PACKET_MODE)) axi_extract_tlast_i (
      .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
      .i_tdata(i_pip_tdata), .i_tvalid(i_pip_tvalid & ~bist_checker_en_reg & ~bist_loopback_en_reg), .i_tready(i_pip_tready),
      .o_tdata(i_pkt_tdata), .o_tlast(i_pkt_tlast), .o_tvalid(i_pkt_tvalid), .o_tready(i_pkt_tready),
      .checksum_error(checksum_err)
   );

   generate if (PACKET_MODE == 1) begin
      axi_packet_gate #(.WIDTH(64), .SIZE(PACKET_FIFO_SIZE)) ingress_pkt_gate_i (
         .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
         .i_tdata(i_pkt_tdata), .i_tlast(i_pkt_tlast), .i_tvalid(i_pkt_tvalid), .i_tready(i_pkt_tready),
         .i_terror(checksum_err),
         .o_tdata(i_gt_tdata), .o_tlast(i_gt_tlast), .o_tvalid(i_gt_tvalid), .o_tready(i_gt_tready)
      );

      axi_fifo_flop #(.WIDTH(65)) input_pipe_i1 (
         .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
         .i_tdata({i_gt_tlast, i_gt_tdata}), .i_tvalid(i_gt_tvalid), .i_tready(i_gt_tready),
         .o_tdata({m_axis_tlast, m_axis_tdata}), .o_tvalid(m_axis_tvalid), .o_tready(m_axis_tready),
         .space(), .occupied()
      );
   end else begin
      axi_fifo_flop #(.WIDTH(65)) input_pipe_i1 (
         .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
         .i_tdata({i_pkt_tlast, i_pkt_tdata}), .i_tvalid(i_pkt_tvalid), .i_tready(i_pkt_tready),
         .o_tdata({m_axis_tlast, m_axis_tdata}), .o_tvalid(m_axis_tvalid), .o_tready(m_axis_tready),
         .space(), .occupied()
      );
   end endgenerate

   always @(posedge sys_clk)
      if (sys_rst | clear_sysclk)
         checksum_errors <= 32'd0;
      else if ((PACKET_MODE == 1) && i_pkt_tvalid && i_pkt_tready && checksum_err)
         checksum_errors <= checksum_errors + 32'd1;

   // ----------------------------------------------
   // TX Data Path
   // ----------------------------------------------

   wire [63:0]    o_pkt_tdata;
   wire           o_pkt_tlast, o_pkt_tvalid, o_pkt_tready;

   wire [63:0]    o_pip_tdata;
   wire           o_pip_tvalid, o_pip_tready;

   wire [63:0]    o_raw_tdata;
   wire           o_raw_tvalid, o_raw_tready;

   // AXI-Flop to ease timing
   axi_fifo_flop #(.WIDTH(65)) output_pipe_i0 (
      .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
      .i_tdata({s_axis_tlast, s_axis_tdata}), .i_tvalid(s_axis_tvalid), .i_tready(s_axis_tready),
      .o_tdata({o_pkt_tlast, o_pkt_tdata}), .o_tvalid(o_pkt_tvalid), .o_tready(o_pkt_tready),
      .space(), .occupied()
   );

   // Remove tlast escape sequence
   axi_embed_tlast #(.WIDTH(64), .ADD_CHECKSUM(PACKET_MODE)) axi_embed_tlast_i (
      .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
      .i_tdata(o_pkt_tdata), .i_tlast(o_pkt_tlast), .i_tvalid(o_pkt_tvalid), .i_tready(o_pkt_tready),
      .o_tdata(o_pip_tdata), .o_tvalid(o_pip_tvalid), .o_tready(o_pip_tready & ~bist_gen_en_reg & ~bist_loopback_en_reg)
   );

   // AXI-Flop to ease timing
   axi_fifo_flop #(.WIDTH(64)) output_pipe_i1 (
      .clk(sys_clk), .reset(sys_rst), .clear(clear_sysclk),
      .i_tdata(bist_gen_en_reg ? bist_o_tdata : (bist_loopback_en_reg ? loopback_tdata : o_pip_tdata)),
      .i_tvalid(bist_gen_en_reg ? bist_o_tvalid : (bist_loopback_en_reg ? loopback_tvalid : o_pip_tvalid)),
      .i_tready(o_pip_tready),
      .o_tdata(o_raw_tdata), .o_tvalid(o_raw_tvalid), .o_tready(o_raw_tready),
      .space(), .occupied()
   );

   assign bist_o_tready    = o_pip_tready;
   assign loopback_tready  = o_pip_tready;

   // Egress FIFO
   axi64_8k_2clk_fifo egress_fifo_i (
      .s_aresetn(~phy_rst), .s_aclk(sys_clk),
      .s_axis_tdata(o_raw_tdata), .s_axis_tlast(o_raw_tvalid), .s_axis_tuser(4'h0),
      .s_axis_tvalid(o_raw_tvalid), .s_axis_tready(o_raw_tready), .axis_wr_data_count(),
      .m_aclk(phy_clk),
      .m_axis_tdata(phy_m_axis_tdata), .m_axis_tlast(), .m_axis_tuser(),
      .m_axis_tvalid(phy_m_axis_tvalid), .m_axis_tready(phy_m_axis_tready), .axis_rd_data_count()
   );

   // ----------------------------------------------
   // BIST: Generator and checker for a PRBS15 pattern
   // ----------------------------------------------

   generate if (BIST_ENABLED == 1) begin
      localparam [15:0] SEED16 = 16'hFFFF;
      localparam [63:0] SEED64 = {~SEED16, SEED16, ~SEED16, SEED16};
   
      // Throttle outgoing PRBS to based on the specified rate
      // BIST Throughput = sys_clk BW * (1 - (1/N))
      // where: N = bist_gen_rate_reg + 1
      //        N = 0 implies full rate
      reg [4:0] throttle_cnt;
      always @(posedge sys_clk) begin
         if (sys_rst | clear_sysclk)
            throttle_cnt <= bist_gen_rate_reg;
         else if (bist_o_tready)
            if (throttle_cnt == 5'd0)
               throttle_cnt <= bist_gen_rate_reg;
            else
               throttle_cnt <= throttle_cnt - 5'd1;
      end
      assign bist_o_tvalid = (bist_gen_rate_reg == 5'd0) || (throttle_cnt != 5'd0);
   
      // Unsynchronized PRBS15 generator (for BIST output)
      reg [15:0] prbs15_gen, prbs15_check;
      always @(posedge sys_clk) begin
         if (sys_rst | clear_sysclk)
            prbs15_gen <= SEED16;
         else if (bist_o_tready & bist_o_tvalid)
            prbs15_gen <= {prbs15_gen[14:0], prbs15_gen[15] ^ prbs15_gen[14]};
      end
      assign bist_o_tdata = {~prbs15_gen, prbs15_gen, ~prbs15_gen, prbs15_gen};
   
      // Unsynchronized PRBS15 generator (for BIST input)
      wire [15:0] prbs15_next = {prbs15_check[14:0], prbs15_check[15] ^ prbs15_check[14]};
      always @(posedge sys_clk) begin
         if (sys_rst | clear_sysclk | ~bist_checker_en_reg) begin
            bist_checker_locked  <= 1'b0;
            prbs15_check <= SEED16;
         end else if (bist_i_tvalid && bist_i_tready) begin
            prbs15_check <= bist_i_tdata[15:0];
            if (bist_i_tdata == SEED64)
               bist_checker_locked <= 1'b1;
         end
      end
   
      // PRBS15 checker
      always @(posedge sys_clk) begin
         if (bist_checker_locked) begin
            if (bist_i_tvalid & bist_i_tready) begin
               bist_checker_samps <= bist_checker_samps + 48'd1;
               if (bist_i_tdata != {~prbs15_next, prbs15_next, ~prbs15_next, prbs15_next}) begin
                  bist_checker_errors <= bist_checker_errors + 48'd1;
               end
            end
         end else begin
            bist_checker_samps  <= 48'd0;
            bist_checker_errors <= 48'd0;
         end
      end
      assign bist_i_tready = 1'b1;
   end endgenerate

endmodule
