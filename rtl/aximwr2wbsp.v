////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	aximwr2wbsp.v
//
// Project:	Pipelined Wishbone to AXI converter
//
// Purpose:	Convert the three AXI4 write channels to a single wishbone
//		channel to write the results.
//
//	Still need to implement the lock feature.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2016, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory, run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
//
module aximwr2wbsp #(
	parameter C_AXI_ID_WIDTH	= 6, // The AXI id width used for R&W
                                             // This is an int between 1-16
	parameter C_AXI_DATA_WIDTH	= 32,// Width of the AXI R&W data
	parameter C_AXI_ADDR_WIDTH	= 28,	// AXI Address width
	parameter AW			= 26,
	parameter LGFIFO                =  4
	) (
	input	wire			i_axi_clk,	// System clock
	input	wire			i_axi_reset_n,

// AXI write address channel signals
	output	wire			o_axi_awready, // Slave is ready to accept
	input	wire	[C_AXI_ID_WIDTH-1:0]	i_axi_awid,	// Write ID
	input	wire	[C_AXI_ADDR_WIDTH-1:0]	i_axi_awaddr,	// Write address
	input	wire	[7:0]		i_axi_awlen,	// Write Burst Length
	input	wire	[2:0]		i_axi_awsize,	// Write Burst size
	input	wire	[1:0]		i_axi_awburst,	// Write Burst type
	input	wire	[0:0]		i_axi_awlock,	// Write lock type
	input	wire	[3:0]		i_axi_awcache,	// Write Cache type
	input	wire	[2:0]		i_axi_awprot,	// Write Protection type
	input	wire	[3:0]		i_axi_awqos,	// Write Quality of Svc
	input	wire			i_axi_awvalid,	// Write address valid
  
// AXI write data channel signals
	output	wire			o_axi_wready,  // Write data ready
	input	wire	[C_AXI_DATA_WIDTH-1:0]	i_axi_wdata,	// Write data
	input	wire	[C_AXI_DATA_WIDTH/8-1:0] i_axi_wstrb,	// Write strobes
	input	wire			i_axi_wlast,	// Last write transaction   
	input	wire			i_axi_wvalid,	// Write valid
  
// AXI write response channel signals
	output	wire [C_AXI_ID_WIDTH-1:0] o_axi_bid,	// Response ID
	output	wire [1:0]		o_axi_bresp,	// Write response
	output	wire			o_axi_bvalid,  // Write reponse valid
	input	wire			i_axi_bready,  // Response ready
  
	// We'll share the clock and the reset
	output	reg			o_wb_cyc,
	output	reg			o_wb_stb,
	output	wire [(AW-1):0]		o_wb_addr,
	output	wire [(C_AXI_DATA_WIDTH-1):0]	o_wb_data,
	output	wire [(C_AXI_DATA_WIDTH/8-1):0]	o_wb_sel,
	input	wire			i_wb_ack,
	input	wire			i_wb_stall,
	// input	[(C_AXI_DATA_WIDTH-1):0]	i_wb_data,
	input	wire			i_wb_err
);

	localparam	DW = C_AXI_DATA_WIDTH;

	wire	w_reset;
	assign	w_reset = (i_axi_reset_n == 1'b0);

	//
	//
	//
	reg	[LGFIFO-1:0]	fifo_ahead, fifo_dhead, fifo_neck, fifo_torso,
				fifo_tail;
	wire	[LGFIFO-1:0]	next_ahead, next_dhead, next_neck, next_torso,
				next_tail;
	assign	next_ahead = fifo_ahead + 1;
	assign	next_dhead = fifo_dhead + 1;
	assign	next_neck  = fifo_neck  + 1;
	assign	next_torso = fifo_torso + 1;
	assign	next_tail  = fifo_tail  + 1;

	reg	[(C_AXI_ID_WIDTH+AW)-1:0]	afifo	[0:((1<<(LGFIFO))-1)];
	reg	[(DW + DW/8)-1:0]		dfifo	[0:((1<<(LGFIFO))-1)];
	reg	[0:((1<<(LGFIFO))-1)]		efifo;

	reg	[(C_AXI_ID_WIDTH+AW)-1:0]	afifo_at_neck, afifo_at_tail;
	reg	[(DW + DW/8)-1:0]		dfifo_at_neck;
	reg					efifo_at_tail;

	reg	filling_fifo, incr;
	reg	[7:0]	len;
	reg	[(AW-1):0]	wr_fifo_addr;
	reg	[(C_AXI_ID_WIDTH-1):0]	wr_fifo_id;

	wire	fifo_full;
	assign	fifo_full = (next_ahead == fifo_tail)||(next_dhead ==fifo_tail);

	initial	fifo_ahead = 0;
	initial	fifo_dhead = 0;
	always @(posedge i_axi_clk)
	begin
		if (filling_fifo)
		begin
			if (!fifo_full)
			begin
				len <= len - 1;
				if (len == 1)
					filling_fifo <= 1'b0;
				fifo_ahead <= next_ahead;
				wr_fifo_addr <= wr_fifo_addr
					+ {{(AW-1){1'b0}},incr};
			end
		end else begin
			wr_fifo_addr <= i_axi_awaddr[(C_AXI_ADDR_WIDTH-1):(C_AXI_ADDR_WIDTH-AW)];
			wr_fifo_id   <= i_axi_awid;
			incr         <= i_axi_awburst[0];
			if ((o_axi_awready)&&(i_axi_awvalid))
			begin
				fifo_ahead <= next_ahead;
				len <= i_axi_awlen;
				filling_fifo <= (i_axi_awlen != 0);
			end
		end

		if (w_reset)
		begin
			fifo_ahead <= 0;
			len <= 0;
			filling_fifo <= 0;
		end
	end

	always @(posedge i_axi_clk)
		afifo[fifo_ahead] <= { wr_fifo_id, wr_fifo_addr };

	initial	fifo_dhead = 0;
	always @(posedge i_axi_clk)
		if (w_reset)
			fifo_dhead <= 0;
		else if ((o_axi_wready)&&(i_axi_wvalid))
			fifo_dhead <= next_dhead;

	always @(posedge i_axi_clk)
		dfifo[fifo_dhead] <= { i_axi_wstrb, i_axi_wdata };


	reg	err_state;

	initial	o_wb_cyc   = 0;
	initial o_wb_stb   = 0;
	initial fifo_neck  = 0;
	initial fifo_torso = 0;
	initial err_state  = 0;
	always @(posedge i_axi_clk)
	begin
		if (w_reset)
		begin
			o_wb_cyc <= 0;
			o_wb_stb <= 0;

			fifo_neck <= 0;
			fifo_torso <= 0;

			err_state <= 0;
		end else if (o_wb_stb)
		begin
			if (i_wb_err)
			begin
				o_wb_stb <= 1'b0;
				err_state <= 1'b0;
			end
			else if (!i_wb_stall)
				o_wb_stb <= (fifo_ahead != next_neck)
					&&(fifo_dhead != next_neck);

			if (!i_wb_stall)
				fifo_neck <= next_neck;

			if (i_wb_ack)
				fifo_torso <= next_torso;

			if (fifo_neck == next_torso)
				o_wb_cyc <= 1'b0;
		end else if (err_state)
		begin
			o_wb_cyc <= 1'b0;
			fifo_torso <= next_torso;
			if (fifo_neck == next_torso)
				err_state <= 1'b0;
		end else if (o_wb_cyc)
		begin
			if (i_wb_ack)
				fifo_torso <= next_torso;
			if (fifo_neck == next_torso)
				o_wb_cyc <= 1'b0;
		end else if((fifo_ahead!= next_neck)&&(fifo_dhead != next_neck))
		begin
			o_wb_cyc <= 1;
			o_wb_stb <= 1;
		end
	end

	initial	efifo = 0;
	always @(posedge i_axi_clk)
		if(w_reset)
			efifo <= 0;
		else
			efifo[fifo_torso] <= (i_wb_err)||(err_state);

	always @(posedge i_axi_clk)
		afifo_at_neck <= afifo[fifo_neck];
	assign	o_wb_addr = afifo_at_neck[(AW-1):0];

	always @(posedge i_axi_clk)
		dfifo_at_neck <= dfifo[fifo_neck];
	assign	o_wb_data = dfifo_at_neck[DW-1:0];
	assign	o_wb_sel  = dfifo_at_neck[(DW+(DW/8))-1:DW];

	initial	fifo_tail = 0;
	always @(posedge i_axi_clk)
		if (w_reset)
			fifo_tail <= 0;
		else if ((o_axi_bvalid)&&(i_axi_bready))
			fifo_tail <= next_tail;

	always @(posedge i_axi_clk)
		afifo_at_tail <= afifo[fifo_tail];
	always @(posedge i_axi_clk)
		efifo_at_tail <= efifo[fifo_tail];

	assign	o_axi_bid   = afifo_at_tail[(C_AXI_ID_WIDTH+AW)-1:AW];
	assign	o_axi_bresp = {(2){efifo_at_tail}};

	assign	o_axi_bvalid  = (fifo_tail  != fifo_torso);
	assign	o_axi_awready = (next_ahead != fifo_tail);
	assign	o_axi_wready  = (next_dhead != fifo_tail);

	// Make Verilator happy
	// verilator lint_on  UNUSED
	wire	[(C_AXI_ID_WIDTH+AW+C_AXI_ADDR_WIDTH-AW)
		+(1)+1+3+1+4+3+4-1:0]	unused;
	assign	unused = { i_axi_awburst[1], i_axi_awsize,
			i_axi_awlock, i_axi_awcache, i_axi_awprot,
			i_axi_awqos, i_axi_wlast,
			afifo_at_neck[(C_AXI_ID_WIDTH+AW-1):AW],
			afifo_at_tail[(AW-1):0],
			i_axi_awaddr[(C_AXI_ADDR_WIDTH-AW)-1:0] };
	// verilator lint_off UNUSED

`ifdef	FORMAL
	always @(*)
		assume(!i_axi_awburst[1]);

	reg	f_past_valid;
	initial	f_past_valid = 1'b0;
	always @(posedge i_axi_clk)
		f_past_valid <= 1'b1;

`ifdef	NOT_YET_READY
	always @(posedge i_axi_clk)
	if (f_past_valid)&&($past(i_axi_reset_n))
	begin
		if ($past(fifo_head))!=($past(fifo_tail))
			assert($past(i_wb_ack)||(err_state)
				||(fifo_head != fifo_tail));

		if (fifo_ahead == fifo_tail)
			assert(fifo_neck == fifo_tail);
		if (fifo_dhead == fifo_tail)
			assert(fifo_neck == fifo_tail);
		if (fifo_ahead > fifo_tail)
		begin
			assert(fifo_neck < fifo_ahead);
			assert(fifo_neck < fifo_dhead);
		end
	end
`endif
`endif
endmodule

