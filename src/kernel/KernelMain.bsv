import FIFO::*;
import Vector::*;

import Processor::*;
import Defines::*;
import Cache::*;

typedef 2 MemPortCnt;

interface MemPortIfc;
	method ActionValue#(MemPortReq) readReq;
	method ActionValue#(MemPortReq) writeReq;
	method ActionValue#(Bit#(512)) writeWord;
	method Action readWord(Bit#(512) word);
endinterface

interface KernelMainIfc;
	method Action start(Bit#(32) param);
	method Action done;
	interface Vector#(MemPortCnt, MemPortIfc) mem;
endinterface

module mkKernelMain(KernelMainIfc);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) writeWordQs <- replicateM(mkFIFO);
	Vector#(MemPortCnt, FIFO#(Bit#(512))) readWordQs <- replicateM(mkFIFO);
	Reg#(Bit#(32)) cycleCounter <- mkReg(0);
	rule incCycle;
		cycleCounter <= cycleCounter + 1;
	endrule

	//////////////////////////////////////////////////////////////////////////

	ProcessorIfc processor <- mkProcessor;
	Vector#(2, CacheIfc#(12)) caches;
	caches[0] <- mkCacheDirect(False);
	caches[1] <- mkCacheDirect(True);
	//CacheIfc#(32,12,4) iCache <- mkCacheDirect;

	rule prociMemReq;
		MemReq32 req <- processor.iMemReq;
		caches[0].cacheReq(req);
	endrule
	rule prociMemResp;
		let w <- caches[0].cacheResp;
		processor.iMemResp(w);
	endrule
	rule procdMemReq;
		MemReq32 req <- processor.dMemReq;
		//$write( "dMem req %x %d\n", req.addr, req.bytes );
		caches[1].cacheReq(req);
		if ( req.addr== 32'hfff && req.write ) begin
			$write( "++++\t\t %x\n", req.word );
		end
	endrule
	rule procdMemResp;
		let w <- caches[1].cacheResp;
		processor.dMemResp(w);
	endrule
	for ( Integer di = 0; di < 2; di=di+1 ) begin
		rule procCacheRead;
			let rr <- caches[di].memReadReq;
			readReqQs[di].enq(rr);
		endrule
		rule procCacheWrite;
			let rr <- caches[di].memWriteReq;
			writeReqQs[di].enq(rr);
		endrule
		rule procWordWrite;
			let rr <- caches[di].memWriteWord;
			writeWordQs[di].enq(rr);
		endrule
		rule procWordRead;
			let d = readWordQs[di].first;
			readWordQs[di].deq;
			caches[di].memReadWord(d);
		endrule
	end

	//////////////////////////////////////////////////////////////////////////




	Reg#(Bool) kernelDone <- mkReg(False);
	
	Vector#(MemPortCnt, MemPortIfc) mem_;
	for (Integer i = 0; i < valueOf(MemPortCnt); i=i+1) begin
		mem_[i] = interface MemPortIfc;
			method ActionValue#(MemPortReq) readReq;
				readReqQs[i].deq;
				return readReqQs[i].first;
			endmethod
			method ActionValue#(MemPortReq) writeReq;
				writeReqQs[i].deq;
				return writeReqQs[i].first;
			endmethod
			method ActionValue#(Bit#(512)) writeWord;
				writeWordQs[i].deq;
				return writeWordQs[i].first;
			endmethod
			method Action readWord(Bit#(512) word);
				readWordQs[i].enq(word);
			endmethod
		endinterface;
	end
	method Action start(Bit#(32) param);
	endmethod
	method Action done if (kernelDone);
	endmethod
	interface mem = mem_;
endmodule
