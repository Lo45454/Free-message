(() => {
 const chat=document.getElementById('chat'),back=document.getElementById('back');
 const media=matchMedia('(max-width:760px)');
 let lastPeer='';
 function fit(){
   if(!media.matches||!document.body.classList.contains('chat-open'))return;
   const main=document.querySelector('main');
   const bottom=window.visualViewport ? window.visualViewport.height+window.visualViewport.offsetTop : window.innerHeight;
   const top=main.getBoundingClientRect().top+window.scrollY;
   document.documentElement.style.setProperty('--chat-height',Math.max(280,bottom-top)+'px');
 }
 function sync(){
   const title=document.getElementById('title').textContent;
   if(chat.hidden){document.body.classList.remove('chat-open');lastPeer='';}
   else if(title!==lastPeer){lastPeer=title;document.body.classList.add('chat-open');window.scrollTo(0,0);}
   requestAnimationFrame(fit);
 }
 new MutationObserver(sync).observe(chat,{attributes:true,attributeFilter:['hidden']});
 new MutationObserver(sync).observe(document.getElementById('title'),{childList:true,subtree:true,characterData:true});
 back.addEventListener('click',()=>{document.body.classList.remove('chat-open');lastPeer='';window.scrollTo(0,0)});
 // Reopening the same friend updates the title, triggering sync.
 window.addEventListener('resize',fit);
 window.visualViewport?.addEventListener('resize',fit);
 window.visualViewport?.addEventListener('scroll',fit);
 document.getElementById('text').addEventListener('focus',()=>setTimeout(fit,250));
 sync();
})();