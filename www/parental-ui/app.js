async function refresh(){
 const res=await fetch("/ubus",{method:"POST",headers:{"Content-Type":"application/json"},
  body:JSON.stringify({"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","parental","get_overview",{}]})});
 const js=await res.json();
 document.getElementById("status").innerText="Connected. "+(js.result? "Got data":"Error");
}
refresh();
setInterval(refresh,30000);
