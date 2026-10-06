// =============================================================================
// addr_decoder.sv — OBI Address Decoder with Transaction Tracking (PE v4)
//   (R3.1: WAIT_RESP gating — suppress grant while outstanding, C9 fix)
//
// Routes IBEX data-port OBI transactions to the correct slave:
//   0x0001_0000 – 0x0001_0FFF : L1D SRAM  (4KB)
//   0x0002_0000 – 0x0002_00FF : MMIO      (256B — CP CSR, Region Table)
//   Others                    : Unmapped  → err=1, rdata=0xDEADBEEF
//
// Design:
//   IBEX LSU issues at most 1 outstanding data transaction.
//   1-entry state machine tracks which slave owns the response phase.
//
//   State Machine:
//     IDLE ──(req & gnt)──► WAIT_RESP ──(rvalid)──► IDLE
//                                │                    ▲
//                     slave_id latched          (or back-to-back
//                     held until rvalid          handshake → WAIT_RESP)
//
// Note: L1I is NOT routed here — IBEX instruction port connects directly
//       to l1i_mem via pe_top.  L2 is NOT in IBEX address space.
// =============================================================================

module addr_decoder
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // =========================================================================
    // Upstream: IBEX Data Interface (OBI Master)
    // =========================================================================
    input  logic        cpu_req_i,
    output logic        cpu_gnt_o,
    output logic        cpu_rvalid_o,
    input  logic [31:0] cpu_addr_i,
    input  logic        cpu_we_i,
    input  logic [3:0]  cpu_be_i,
    input  logic [31:0] cpu_wdata_i,
    output logic [31:0] cpu_rdata_o,
    output logic        cpu_err_o,

    // =========================================================================
    // Downstream: L1D SRAM (OBI Slave, Port 0 RW)
    // =========================================================================
    output logic        l1d_req_o,
    input  logic        l1d_gnt_i,
    input  logic        l1d_rvalid_i,
    output logic [11:0] l1d_addr_o,      // 12-bit byte address (4KB)
    output logic        l1d_we_o,
    output logic [3:0]  l1d_be_o,
    output logic [31:0] l1d_wdata_o,
    input  logic [31:0] l1d_rdata_i,
    input  logic        l1d_err_i,

    // =========================================================================
    // Downstream: MMIO — CP CSR / Region Table (OBI Slave)
    // =========================================================================
    output logic        mmio_req_o,
    input  logic        mmio_gnt_i,
    input  logic        mmio_rvalid_i,
    output logic [8:0]  mmio_addr_o,     // 9-bit byte address (512B, D7)
    output logic        mmio_we_o,
    output logic [3:0]  mmio_be_o,
    output logic [31:0] mmio_wdata_o,
    input  logic [31:0] mmio_rdata_i,
    input  logic        mmio_err_i
);

    // =========================================================================
    // Slave ID Encoding
    // =========================================================================
    typedef enum logic [1:0] {
        SLV_NONE     = 2'b00,
        SLV_L1D      = 2'b01,
        SLV_MMIO     = 2'b10,
        SLV_UNMAPPED = 2'b11
    } slave_id_e;

    // =========================================================================
    // Address Hit Detection (Combinational)
    // =========================================================================
    logic addr_hit_l1d;
    logic addr_hit_mmio;
    slave_id_e target_slave;

    // L1D: 0x0001_0000 – 0x0001_0FFF
    //   addr[31:16] == 0x0001 && addr[15:12] == 0x0
    assign addr_hit_l1d  = (cpu_addr_i[31:16] == 16'h0001) &
                           (cpu_addr_i[15:12] == 4'h0);

    // MMIO: 0x0002_0000 – 0x0002_01FF  (D7: 512B, was 256B)
    //   addr[31:16] == 0x0002 && addr[15:9] == 7'b0
    assign addr_hit_mmio = (cpu_addr_i[31:16] == 16'h0002) &
                           (cpu_addr_i[15:9]  == 7'b0);

    always_comb begin
        if (addr_hit_l1d)
            target_slave = SLV_L1D;
        else if (addr_hit_mmio)
            target_slave = SLV_MMIO;
        else
            target_slave = SLV_UNMAPPED;
    end

    // =========================================================================
    // Request Routing (Combinational — Address Phase)
    //
    // R3.1: Suppress downstream req while outstanding (WAIT_RESP && !rvalid).
    //   Prevents phantom transactions in downstream slaves when grant is suppressed.
    //   Back-to-back (rvalid same cycle) is allowed — req flows through normally.
    // =========================================================================
    logic gnt_suppress;
    assign gnt_suppress = (state_q == ST_WAIT_RESP) & ~resp_rvalid;

    assign l1d_req_o  = cpu_req_i & addr_hit_l1d  & ~gnt_suppress;
    assign mmio_req_o = cpu_req_i & addr_hit_mmio & ~gnt_suppress;

    // L1D: pass lower 12 bits as byte address within 4KB
    assign l1d_addr_o  = cpu_addr_i[11:0];
    assign l1d_we_o    = cpu_we_i;
    assign l1d_be_o    = cpu_be_i;
    assign l1d_wdata_o = cpu_wdata_i;

    // MMIO: pass lower 9 bits as byte address within 512B (D7: expanded from 256B)
    assign mmio_addr_o  = cpu_addr_i[8:0];
    assign mmio_we_o    = cpu_we_i;
    assign mmio_be_o    = cpu_be_i;
    assign mmio_wdata_o = cpu_wdata_i;

    // =========================================================================
    // Grant Routing (Combinational)
    //
    // R3.1 (C9 fix): When an outstanding transaction is pending (WAIT_RESP)
    //   and the response hasn't arrived (!resp_rvalid), force cpu_gnt_o = 0.
    //   This makes the decoder safe with multi-outstanding masters (future
    //   CPU core swap), rather than relying on IBEX's 1-outstanding guarantee.
    //
    //   Back-to-back pipelining preserved: when resp_rvalid is asserted on
    //   the same cycle as a new request, gnt_suppress = 0 and the new
    //   transaction is granted normally (IBEX-compatible).
    // =========================================================================
    always_comb begin
        if (gnt_suppress) begin
            cpu_gnt_o = 1'b0;
        end else begin
            case (target_slave)
                SLV_L1D:      cpu_gnt_o = l1d_gnt_i;
                SLV_MMIO:     cpu_gnt_o = mmio_gnt_i;
                SLV_UNMAPPED: cpu_gnt_o = cpu_req_i;   // always grant unmapped (1-cycle error)
                default:      cpu_gnt_o = 1'b0;
            endcase
        end
    end

    // =========================================================================
    // Outstanding Transaction Tracker (1-entry, matches IBEX LSU)
    //
    // IBEX guarantees: at most 1 outstanding data request.
    // Latch slave ID on successful handshake (req & gnt), hold until rvalid.
    // =========================================================================
    logic handshake;
    assign handshake = cpu_req_i & cpu_gnt_o;

    typedef enum logic {
        ST_IDLE      = 1'b0,
        ST_WAIT_RESP = 1'b1
    } state_e;

    state_e    state_q,      state_d;
    slave_id_e resp_slave_q, resp_slave_d;
    logic      resp_rvalid;

    always_comb begin
        state_d      = state_q;
        resp_slave_d = resp_slave_q;
        resp_rvalid  = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (handshake) begin
                    state_d      = ST_WAIT_RESP;
                    resp_slave_d = target_slave;
                end
            end

            ST_WAIT_RESP: begin
                case (resp_slave_q)
                    SLV_L1D:      resp_rvalid = l1d_rvalid_i;
                    SLV_MMIO:     resp_rvalid = mmio_rvalid_i;
                    SLV_UNMAPPED: resp_rvalid = 1'b1;   // immediate error response
                    default:      resp_rvalid = 1'b1;
                endcase

                if (resp_rvalid) begin
                    // Back-to-back: if a new handshake happens on the same cycle
                    if (handshake) begin
                        state_d      = ST_WAIT_RESP;
                        resp_slave_d = target_slave;
                    end else begin
                        state_d = ST_IDLE;
                    end
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q      <= ST_IDLE;
            resp_slave_q <= SLV_NONE;
        end else begin
            state_q      <= state_d;
            resp_slave_q <= resp_slave_d;
        end
    end

    // =========================================================================
    // Response Routing (Data Phase — driven by tracked slave ID)
    // =========================================================================
    assign cpu_rvalid_o = (state_q == ST_WAIT_RESP) & resp_rvalid;

    always_comb begin
        case (resp_slave_q)
            SLV_L1D: begin
                cpu_rdata_o = l1d_rdata_i;
                cpu_err_o   = l1d_err_i;
            end
            SLV_MMIO: begin
                cpu_rdata_o = mmio_rdata_i;
                cpu_err_o   = mmio_err_i;
            end
            SLV_UNMAPPED: begin
                cpu_rdata_o = 32'hDEAD_BEEF;
                cpu_err_o   = 1'b1;
            end
            default: begin
                cpu_rdata_o = 32'h0;
                cpu_err_o   = 1'b0;
            end
        endcase
    end

endmodule
