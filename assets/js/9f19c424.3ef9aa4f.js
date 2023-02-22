"use strict";(self.webpackChunkfirezone_docs=self.webpackChunkfirezone_docs||[]).push([[5243],{3905:(e,t,n)=>{n.d(t,{Zo:()=>d,kt:()=>m});var o=n(7294);function r(e,t,n){return t in e?Object.defineProperty(e,t,{value:n,enumerable:!0,configurable:!0,writable:!0}):e[t]=n,e}function a(e,t){var n=Object.keys(e);if(Object.getOwnPropertySymbols){var o=Object.getOwnPropertySymbols(e);t&&(o=o.filter((function(t){return Object.getOwnPropertyDescriptor(e,t).enumerable}))),n.push.apply(n,o)}return n}function i(e){for(var t=1;t<arguments.length;t++){var n=null!=arguments[t]?arguments[t]:{};t%2?a(Object(n),!0).forEach((function(t){r(e,t,n[t])})):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(n)):a(Object(n)).forEach((function(t){Object.defineProperty(e,t,Object.getOwnPropertyDescriptor(n,t))}))}return e}function l(e,t){if(null==e)return{};var n,o,r=function(e,t){if(null==e)return{};var n,o,r={},a=Object.keys(e);for(o=0;o<a.length;o++)n=a[o],t.indexOf(n)>=0||(r[n]=e[n]);return r}(e,t);if(Object.getOwnPropertySymbols){var a=Object.getOwnPropertySymbols(e);for(o=0;o<a.length;o++)n=a[o],t.indexOf(n)>=0||Object.prototype.propertyIsEnumerable.call(e,n)&&(r[n]=e[n])}return r}var s=o.createContext({}),c=function(e){var t=o.useContext(s),n=t;return e&&(n="function"==typeof e?e(t):i(i({},t),e)),n},d=function(e){var t=c(e.components);return o.createElement(s.Provider,{value:t},e.children)},p="mdxType",g={inlineCode:"code",wrapper:function(e){var t=e.children;return o.createElement(o.Fragment,{},t)}},u=o.forwardRef((function(e,t){var n=e.components,r=e.mdxType,a=e.originalType,s=e.parentName,d=l(e,["components","mdxType","originalType","parentName"]),p=c(n),u=r,m=p["".concat(s,".").concat(u)]||p[u]||g[u]||a;return n?o.createElement(m,i(i({ref:t},d),{},{components:n})):o.createElement(m,i({ref:t},d))}));function m(e,t){var n=arguments,r=t&&t.mdxType;if("string"==typeof e||r){var a=n.length,i=new Array(a);i[0]=u;var l={};for(var s in t)hasOwnProperty.call(t,s)&&(l[s]=t[s]);l.originalType=e,l[p]="string"==typeof e?e:r,i[1]=l;for(var c=2;c<a;c++)i[c]=n[c];return o.createElement.apply(null,i)}return o.createElement.apply(null,n)}u.displayName="MDXCreateElement"},7943:(e,t,n)=>{n.r(t),n.d(t,{assets:()=>s,contentTitle:()=>i,default:()=>g,frontMatter:()=>a,metadata:()=>l,toc:()=>c});var o=n(7462),r=(n(7294),n(3905));const a={title:"Debug Logs",sidebar_position:8,description:"Docker deployments of Firezone generate and store debug logs to a JSON file on the host machine."},i=void 0,l={unversionedId:"administer/debug-logs",id:"administer/debug-logs",title:"Debug Logs",description:"Docker deployments of Firezone generate and store debug logs to a JSON file on the host machine.",source:"@site/docs/administer/debug-logs.mdx",sourceDirName:"administer",slug:"/administer/debug-logs",permalink:"/docs/administer/debug-logs",draft:!1,editUrl:"https://github.com/firezone/firezone/blob/master/www/docs/administer/debug-logs.mdx",tags:[],version:"current",sidebarPosition:8,frontMatter:{title:"Debug Logs",sidebar_position:8,description:"Docker deployments of Firezone generate and store debug logs to a JSON file on the host machine."},sidebar:"tutorialSidebar",previous:{title:"Regenerate Secret Keys",permalink:"/docs/administer/regen-keys"},next:{title:"User Guides",permalink:"/docs/user-guides/"}},s={},c=[{value:"Managing and configuring Docker logs",id:"managing-and-configuring-docker-logs",level:2}],d={toc:c},p="wrapper";function g(e){let{components:t,...n}=e;return(0,r.kt)(p,(0,o.Z)({},d,n,{components:t,mdxType:"MDXLayout"}),(0,r.kt)("admonition",{type:"note"},(0,r.kt)("p",{parentName:"admonition"},"This article is written for Docker based deployments of Firezone.")),(0,r.kt)("p",null,"Docker deployments of Firezone consist of 3 running containers:"),(0,r.kt)("table",null,(0,r.kt)("thead",{parentName:"table"},(0,r.kt)("tr",{parentName:"thead"},(0,r.kt)("th",{parentName:"tr",align:null},"Container"),(0,r.kt)("th",{parentName:"tr",align:null},"Function"),(0,r.kt)("th",{parentName:"tr",align:null},"Example logs"))),(0,r.kt)("tbody",{parentName:"table"},(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"firezone"),(0,r.kt)("td",{parentName:"tr",align:null},"Web portal"),(0,r.kt)("td",{parentName:"tr",align:null},"HTTP requests received and responses provided")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"postgres"),(0,r.kt)("td",{parentName:"tr",align:null},"Database"),(0,r.kt)("td",{parentName:"tr",align:null})),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"caddy"),(0,r.kt)("td",{parentName:"tr",align:null},"Reverse proxy"),(0,r.kt)("td",{parentName:"tr",align:null})))),(0,r.kt)("p",null,"Each container generates and stores logs to a JSON file on the host\nmachine. These files can be found at\n",(0,r.kt)("inlineCode",{parentName:"p"},"var/lib/docker/containers/{CONTAINER_ID}/{CONTAINER_ID}-json.log"),"."),(0,r.kt)("p",null,"Run the ",(0,r.kt)("inlineCode",{parentName:"p"},"docker compose logs")," command to view the log output from all running\ncontainers. Note, ",(0,r.kt)("inlineCode",{parentName:"p"},"docker compose")," commands need to be run in the Firezone\nroot directory. This is ",(0,r.kt)("inlineCode",{parentName:"p"},"$HOME/.firezone")," by default."),(0,r.kt)("p",null,"See additional options of the ",(0,r.kt)("inlineCode",{parentName:"p"},"docker compose logs")," command\n",(0,r.kt)("a",{parentName:"p",href:"https://docs.docker.com/engine/reference/commandline/compose_logs/"},"here"),"."),(0,r.kt)("admonition",{type:"note"},(0,r.kt)("p",{parentName:"admonition"},"Audit logs are in early Beta on the Enterprise plan. These track configuration\nchanges by admins and network activity by users.\n",(0,r.kt)("a",{parentName:"p",href:"/sales"},"Contact us"),"\nto learn more.")),(0,r.kt)("h2",{id:"managing-and-configuring-docker-logs"},"Managing and configuring Docker logs"),(0,r.kt)("p",null,"By default, Firezone uses the ",(0,r.kt)("inlineCode",{parentName:"p"},"json-file")," logging driver without\n",(0,r.kt)("a",{parentName:"p",href:"https://docs.docker.com/config/containers/logging/json-file/"},"additional configuration"),".\nThis means logs from each container are individually stored in a file format\ndesigned to be exclusively accessed by the Docker daemon. Log rotation is not\nenabled, so logs on the host can build up and consume excess storage space."),(0,r.kt)("p",null,"For production deployments of Firezone you may want to configure how logs are\ncollected and stored. Docker provides\n",(0,r.kt)("a",{parentName:"p",href:"https://docs.docker.com/config/containers/logging/configure/"},"multiple mechanisms"),"\nto collect information from running containers and services."),(0,r.kt)("p",null,"Examples of popular plugins, configurations, and use cases are:"),(0,r.kt)("ul",null,(0,r.kt)("li",{parentName:"ul"},"Export container logs to your SIEM or observability platform (i.e.\n",(0,r.kt)("a",{parentName:"li",href:"https://docs.docker.com/config/containers/logging/splunk/"},"Splunk"),"\nor\n",(0,r.kt)("a",{parentName:"li",href:"https://docs.docker.com/config/containers/logging/gcplogs/"},"Google Cloud Logging"),"\n)"),(0,r.kt)("li",{parentName:"ul"},"Enable log rotation and max file size."),(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("a",{parentName:"li",href:"https://docs.docker.com/config/containers/logging/log_tags/"},"Customize log driver output"),"\nwith tags.")))}g.isMDXComponent=!0}}]);