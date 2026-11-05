import pathlib,sys,json,re,argparse
parser=argparse.ArgumentParser()
for name in ["before","after","corpus","output"]: parser.add_argument("--"+name,required=True)
args=parser.parse_args()
sys.path.insert(0,str(pathlib.Path.cwd()/'scripts'))
from benchmark_context import MCP,estimate
cases=[('usage','오늘 관측 토큰 사용량 수집 누락','Sources/ContextOSCore/Registry/ConcurrentUsageReader.swift'),('context','컨텍스트 최적화 토큰 예산','Sources/ContextOSCore/Optimizer/ContextOptimizer.swift'),('dedup','컨텍스트 중복 전달 절감','Sources/ContextOSCore/Service/SessionMemory.swift'),('dependencies','의존성 코드 누락 본문 슬라이싱','Sources/ContextOSCore/Optimizer/CodeSlicer.swift')]
out=[]
for label,binary in [('before',args.before),('after',args.after)]:
 server=MCP(binary)
 try:
  init,_=server.request('initialize',{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'natural-language-audit','version':'1'}})
  root=pathlib.Path(args.corpus);server.call('index_project',root)
  rows=[]
  for name,query,path in cases:
   plan,_=server.call('get_relevant_context',root,query=query,token_budget=8000)
   paths=re.findall(r'^  - (.*?)  \(',plan,re.M)
   body,_=server.call('read_optimized',root,query=query,token_budget=8000,fresh=True)
   delivered=re.findall(r'^// ===== FILE: (.*?)(?:  \(| =====)',body,re.M)
   rows.append(dict(case=name,query=query,expected=path,selected=paths[:3],essential_in_top_3=path in paths[:3],delivered=path in delivered,estimated_tokens=estimate(body),within_budget=estimate(body)<=8000))
  out.append(dict(version=label,server_instructions=bool(init.get('instructions')),queries=rows,top3=sum(r['essential_in_top_3'] for r in rows),delivered=sum(r['delivered'] for r in rows)))
 finally:server.close()
pathlib.Path(args.output).write_text(json.dumps(out,ensure_ascii=False,indent=2))
print(json.dumps([{k:v for k,v in item.items() if k!='queries'} for item in out],ensure_ascii=False))
