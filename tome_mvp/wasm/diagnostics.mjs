// Local, bounded diagnostics. Nothing is sent to a server.
export class DiagnosticRecorder {
  constructor(build) {this.build=build;this.seed=null;this.requests=[];this.lines=[];this.last=null;this.first=null;this.nativeReports=[];this.nativeReportCount=0;}
  log(...parts) {this.lines.push(parts.map(String).join(' ').slice(0,2000));if(this.lines.length>256)this.lines.shift();}
  request(method,params,generation) {if(['create','reset'].includes(method) && Number.isInteger(params.seed))this.seed=params.seed;this.requests.push({method,params:structuredClone(params),generation});if(this.requests.length>128)this.requests.shift();}
  observe(s) {this.last=structuredClone(s);}
  nativeReport(text) {this.nativeReportCount++;this.nativeReports.push({request:structuredClone(this.requests.at(-1)),message:String(text).slice(0,24000)});if(this.nativeReports.length>32)this.nativeReports.shift();}
  fail(code,detail) {if(!this.first)this.first={code:String(code).slice(0,300),detail:String(detail).slice(0,65536),requests:structuredClone(this.requests),lines:[...this.lines],last_confirmed:structuredClone(this.last)};}
  export() {return {format:'tome-local-diagnostics-v1',build:this.build,seed:this.seed,first_error:structuredClone(this.first),last_confirmed:structuredClone(this.last),requests:structuredClone(this.requests),lines:[...this.lines],native_report_count:this.nativeReportCount,recoverable_native_reports:[...this.nativeReports]};}
}
