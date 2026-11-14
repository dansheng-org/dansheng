export async function schedule(ctx,input) {
  return ctx.jobs.schedule({plugin_id:'fixture.local-clock',action:'count',account_id:input.account_id,
    run_at:input.run_at, prepare_at:input.prepare_at, deadline_at:input.deadline_at,
    input:{account_id:input.account_id,key:input.key}});
}
export async function read(ctx,input) { return await ctx.storage.get({key:input.key || 'clock'}); }
export async function count(ctx,input) {
  const key=input.key || 'clock'; const old=await ctx.storage.get({key});
  const result={count:(old?.count || 0)+1,at:Date.now()};
  await ctx.storage.set({key,value:result});
  await ctx.ui.publish({id:'clock',component:{type:'detail',title:'本地计数器',value:result.count}});
  return result;
}
