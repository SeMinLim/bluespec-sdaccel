import FIFO::*;
import FIFOF::*;
import SpecialFIFOs::*;

import RFile::*;
import Defines::*;
import Decode::*;
import Execute::*;

import Scoreboard::*;

typedef struct {
	Word pc;
	Word pc_predicted;	// Pipelining
	Bool epoch;		// Pipelining
} F2D deriving(Bits, Eq);

typedef struct {
	Word pc;
	Word pc_predicted;	// Pipelining
	Bool epoch;		// Pipelining
	DecodedInst dInst; 
	Word rVal1; 
	Word rVal2;
} D2E deriving(Bits, Eq);

typedef struct {
	RIndx dst;
	Word data;
} BypassTarget deriving(Bits,Eq);

typedef struct {
	Word pc;
	RIndx dst;

	Bool isMem;

	Word data;
	Bool extendSigned;
	SizeType size;
} E2M deriving(Bits,Eq);

interface ProcessorIfc;
	method ActionValue#(MemReq32) iMemReq;
	method Action iMemResp(Word data);
	method ActionValue#(MemReq32) dMemReq;
	method Action dMemResp(Word data);
endinterface

(* synthesize *)
module mkProcessor(ProcessorIfc);
	Reg#(Word)  pc <- mkReg(0);
	RFile2R1W   rf <- mkRFile2R1W;

	//Reg#(ProcStage) stage <- mkReg(Fetch);
	ScoreboardIfc#(4) sb <- mkScoreboard;		// Pipelining

	FIFOF#(F2D) f2d <- mkSizedFIFOF(2);
    	FIFOF#(D2E) d2e <- mkSizedFIFOF(2);	
	FIFOF#(E2M) e2m <- mkSizedFIFOF(2);

	FIFO#(MemReq32) imemReqQ <- mkFIFO;
	FIFO#(Word) imemRespQ <- mkFIFO;
	FIFO#(MemReq32) dmemReqQ <- mkFIFO;
	FIFO#(Word) dmemRespQ <- mkFIFO;

	FIFOF#(Word) nextpcQ <- mkSizedFIFOF(4);	// Pipelining

	Reg#(Bool) epoch <- mkReg(False);		// Pipelining
	Reg#(Bit#(32)) cycles <- mkReg(0);
	Reg#(Bit#(32)) fetchCnt <- mkReg(0);
	Reg#(Bit#(32)) execCnt <- mkReg(0);
	rule incCycle;
		cycles <= cycles + 1;
	endrule

	rule doFetch;// (stage == Fetch);
		Word curpc = pc;
		if ( nextpcQ.notEmpty ) begin
			nextpcQ.deq;
			curpc = nextpcQ.first;
		end

		Word pc_predicted = curpc + 4;
		pc <= pc_predicted; 			// For next cycle

		imemReqQ.enq(MemReq32{write:False,addr:curpc,word:?,bytes:3});
		f2d.enq(F2D {pc: curpc, pc_predicted:pc_predicted, epoch:epoch});

		$write( "[0x%8x:0x%4x] Fetching instruction count 0x%4x\n", cycles, curpc, fetchCnt );
		fetchCnt <= fetchCnt + 1;
		//stage <= Decode;
	endrule





	Wire#(BypassTarget) forwardE <- mkDWire(BypassTarget{dst:0,data:?});
	rule doDecode;// (stage == Decode);
		let x = f2d.first;
		Word inst = imemRespQ.first;

		let dInst = decode(inst);
		let rVal1 = rf.rd1(dInst.src1);
		let rVal2 = rf.rd2(dInst.src2);

		Bool stallSrc1 = sb.search1(dInst.src1);
		Bool stallSrc2 = sb.search2(dInst.src2);

		if ( forwardE.dst > 0 ) begin
			if ( forwardE.dst == dInst.src1 ) begin
				stallSrc1 = False;
				rVal1 = forwardE.data;
			end
			if ( forwardE.dst == dInst.src2 ) begin
				stallSrc2 = False;
				rVal2 = forwardE.data;
			end
		end

		if ( !stallSrc1 && !stallSrc2 ) begin
			d2e.enq(D2E {pc: x.pc, pc_predicted:x.pc_predicted, epoch:x.epoch, dInst: dInst, rVal1: rVal1, rVal2: rVal2});
			
			f2d.deq;
			imemRespQ.deq;

			sb.enq(dInst.dst);
			$write( "[0x%8x:0x%04x] decoding 0x%08x\n", cycles, x.pc, inst );
		end else begin
			$write( "[0x%8x:0x%04x] decoding stalled -- %d %d\n", cycles, x.pc, dInst.src1, dInst.src2 );
		end
		//stage <= Execute;
	endrule






	rule doExecute;// (stage == Execute);
		D2E x = d2e.first;
		d2e.deq;
		Word pc = x.pc; 
		Word pc_predicted = x.pc_predicted;
		Bool epoch_fetched = x.epoch;
		Word rVal1 = x.rVal1; Word rVal2 = x.rVal2; 
		DecodedInst dInst = x.dInst;

		if ( epoch_fetched == epoch ) begin
			let eInst = exec(dInst, rVal1, rVal2, pc);
			execCnt <= execCnt + 1;

			if ( pc_predicted != eInst.nextPC ) begin
				nextpcQ.enq(eInst.nextPC);
				epoch <= !epoch;
				$write( "[0x%8x:0x%04x] \t\t detected misprediction, jumping to 0x%08x\n", cycles, pc, eInst.nextPC );
			end
		
			if (eInst.iType == Unsupported) begin
				$display("Reached unsupported instruction");
				$display("Total Clock Cycles = %d\nTotal Instruction Count = %d", cycles, execCnt);
				$display("Dumping the state of the processor");
				$display("pc = 0x%x", x.pc);
				//rf.displayRFileInSimulation;
				$display("Quitting simulation.");
				$finish;
			end

			if (eInst.iType == LOAD) begin
				dmemReqQ.enq(MemReq32{write:False,addr:(eInst.addr), word:?, bytes:dInst.size});
				e2m.enq(E2M{dst:eInst.dst,extendSigned:dInst.extendSigned,size:dInst.size, pc:pc, data:0, isMem: True});
				//stage <= Writeback;
				$write( "[0x%8x:0x%04x] \t\t Mem read from 0x%08x\n", cycles, pc, eInst.addr );
			end 
			else if (eInst.iType == STORE) begin
				$display( "Total Clock Cycles = %d\nTotal Instruction Count = %d", cycles, execCnt );
				dmemReqQ.enq(MemReq32{write:True,addr:(eInst.addr), word:eInst.data, bytes:dInst.size});
				$write( "[0x%8x:0x%04x] \t\t MemOp write 0x%08x to 0x%08x\n", cycles, pc, eInst.data, eInst.addr );
				e2m.enq(E2M{dst:0,extendSigned:?,size:?, pc:pc, data:?, isMem: False});
				//stage <= Fetch;
			end
			else begin
				if(eInst.writeDst) begin
					$write( "[0x%8x:0x%04x] rf writing %x to %d\n", cycles, pc, eInst.data, eInst.dst );
					e2m.enq(E2M{dst:eInst.dst,extendSigned:?,size:?, pc:pc, data:eInst.data, isMem: False});
					forwardE <= BypassTarget{dst:eInst.dst, data:eInst.data};
					//stage <= Writeback;
				end else begin
					//stage <= Fetch;
					e2m.enq(E2M{dst:0,extendSigned:?,size:?, pc:pc, data:?, isMem: False});
				end
			end
		end else begin
			$write( "[0x%8x:0x%04x] \t\t ignoring mispredicted instruction\n", cycles, pc );
			e2m.enq(E2M{dst:0,extendSigned:?,size:?,pc:pc,data:?,isMem:False});
		end
		$write( "[0x%8x:0x%04x] Executing\n", cycles, pc );
	endrule







	rule doWriteback;// (stage == Writeback);
		e2m.deq;
		let r = e2m.first;

		Word dw = r.data;
		if ( r.isMem ) begin
			dmemRespQ.deq;
			let data = dmemRespQ.first;

			if ( r.size == 0 ) begin
				if ( r.extendSigned ) begin
					Int#(8) id = unpack(data[7:0]);
					Int#(32) ide = signExtend(id);
					dw = pack(ide);
				end else begin
					dw = zeroExtend(data[7:0]);
				end
			end else if ( r.size == 1 ) begin
				if ( r.extendSigned ) begin
					Int#(16) id = unpack(data[15:0]);
					Int#(32) ide = signExtend(id);
					dw = pack(ide);
				end else begin
					dw = zeroExtend(data[15:0]);
				end
			end else begin
				dw = data;
			end
			$write( "[0x%8x:0x%04x] MemOpRead writing %x to %d\n", cycles, r.pc, dw, r.dst );
		end
		
		$write( "[0x%8x:0x%04x] Writeback writing %x to %d\n", cycles, r.pc, dw, r.dst );
		rf.wr(r.dst, dw);
		sb.deq;
		
		//stage <= Fetch;
	endrule






	method ActionValue#(MemReq32) iMemReq;
		imemReqQ.deq;
		return imemReqQ.first;
	endmethod
	method Action iMemResp(Word data);
		imemRespQ.enq(data);
	endmethod
	method ActionValue#(MemReq32) dMemReq;
		dmemReqQ.deq;
		return dmemReqQ.first;
	endmethod
	method Action dMemResp(Word data);
		dmemRespQ.enq(data);
	endmethod
endmodule
