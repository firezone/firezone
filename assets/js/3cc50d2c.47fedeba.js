"use strict";(self.webpackChunkfirezone_docs=self.webpackChunkfirezone_docs||[]).push([[4385],{3905:(e,t,r)=>{r.d(t,{Zo:()=>c,kt:()=>f});var n=r(7294);function o(e,t,r){return t in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function a(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter((function(t){return Object.getOwnPropertyDescriptor(e,t).enumerable}))),r.push.apply(r,n)}return r}function i(e){for(var t=1;t<arguments.length;t++){var r=null!=arguments[t]?arguments[t]:{};t%2?a(Object(r),!0).forEach((function(t){o(e,t,r[t])})):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):a(Object(r)).forEach((function(t){Object.defineProperty(e,t,Object.getOwnPropertyDescriptor(r,t))}))}return e}function s(e,t){if(null==e)return{};var r,n,o=function(e,t){if(null==e)return{};var r,n,o={},a=Object.keys(e);for(n=0;n<a.length;n++)r=a[n],t.indexOf(r)>=0||(o[r]=e[r]);return o}(e,t);if(Object.getOwnPropertySymbols){var a=Object.getOwnPropertySymbols(e);for(n=0;n<a.length;n++)r=a[n],t.indexOf(r)>=0||Object.prototype.propertyIsEnumerable.call(e,r)&&(o[r]=e[r])}return o}var l=n.createContext({}),p=function(e){var t=n.useContext(l),r=t;return e&&(r="function"==typeof e?e(t):i(i({},t),e)),r},c=function(e){var t=p(e.components);return n.createElement(l.Provider,{value:t},e.children)},u="mdxType",d={inlineCode:"code",wrapper:function(e){var t=e.children;return n.createElement(n.Fragment,{},t)}},m=n.forwardRef((function(e,t){var r=e.components,o=e.mdxType,a=e.originalType,l=e.parentName,c=s(e,["components","mdxType","originalType","parentName"]),u=p(r),m=o,f=u["".concat(l,".").concat(m)]||u[m]||d[m]||a;return r?n.createElement(f,i(i({ref:t},c),{},{components:r})):n.createElement(f,i({ref:t},c))}));function f(e,t){var r=arguments,o=t&&t.mdxType;if("string"==typeof e||o){var a=r.length,i=new Array(a);i[0]=m;var s={};for(var l in t)hasOwnProperty.call(t,l)&&(s[l]=t[l]);s.originalType=e,s[u]="string"==typeof e?e:o,i[1]=s;for(var p=2;p<a;p++)i[p]=r[p];return n.createElement.apply(null,i)}return n.createElement.apply(null,r)}m.displayName="MDXCreateElement"},481:(e,t,r)=>{r.r(t),r.d(t,{assets:()=>l,contentTitle:()=>i,default:()=>d,frontMatter:()=>a,metadata:()=>s,toc:()=>p});var n=r(7462),o=(r(7294),r(3905));const a={title:"Apache",sidebar_position:1},i=void 0,s={unversionedId:"reference/reverse-proxy-templates/apache",id:"reference/reverse-proxy-templates/apache",title:"Apache",description:"The following are example apache configurations",source:"@site/docs/reference/reverse-proxy-templates/apache.mdx",sourceDirName:"reference/reverse-proxy-templates",slug:"/reference/reverse-proxy-templates/apache",permalink:"/docs/reference/reverse-proxy-templates/apache",draft:!1,editUrl:"https://github.com/firezone/firezone/blob/master/www/docs/reference/reverse-proxy-templates/apache.mdx",tags:[],version:"current",sidebarPosition:1,frontMatter:{title:"Apache",sidebar_position:1},sidebar:"tutorialSidebar",previous:{title:"Reverse Proxy Templates",permalink:"/docs/reference/reverse-proxy-templates/"},next:{title:"Traefik",permalink:"/docs/reference/reverse-proxy-templates/traefik"}},l={},p=[{value:"Without SSL termination",id:"without-ssl-termination",level:2},{value:"With SSL termination",id:"with-ssl-termination",level:2}],c={toc:p},u="wrapper";function d(e){let{components:t,...r}=e;return(0,o.kt)(u,(0,n.Z)({},c,r,{components:t,mdxType:"MDXLayout"}),(0,o.kt)("p",null,"The following are example ",(0,o.kt)("a",{parentName:"p",href:"https://httpd.apache.org/"},"apache")," configurations\nwith and without SSL termination."),(0,o.kt)("p",null,"These expect the apache to be running on the same host as Firezone and\n",(0,o.kt)("inlineCode",{parentName:"p"},"default['firezone']['phoenix']['port']")," to be ",(0,o.kt)("inlineCode",{parentName:"p"},"13000"),"."),(0,o.kt)("h2",{id:"without-ssl-termination"},"Without SSL termination"),(0,o.kt)("p",null,"Since Firezone requires HTTPS for the web portal, please bear in mind a\ndownstream proxy will need to terminate SSL connections in this scenario."),(0,o.kt)("p",null,(0,o.kt)("inlineCode",{parentName:"p"},"<server-name>")," needs to be replaced with your domain name."),(0,o.kt)("p",null,"This configuration needs to be placed in\n",(0,o.kt)("inlineCode",{parentName:"p"},"/etc/sites-available/<server-name>.conf")),(0,o.kt)("p",null,"and activated with ",(0,o.kt)("inlineCode",{parentName:"p"},"a2ensite <server-name>")),(0,o.kt)("pre",null,(0,o.kt)("code",{parentName:"pre",className:"language-conf"},'LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so\nLoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so\nLoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so\nLoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so\n<VirtualHost *:80>\n        ServerName <server-name>\n        ProxyPassReverse "/" "http://127.0.0.1:13000/"\n        ProxyPass "/" "http://127.0.0.1:13000/"\n        RewriteEngine on\n        RewriteCond %{HTTP:Upgrade} websocket [NC]\n        RewriteCond %{HTTP:Connection} upgrade [NC]\n        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]\n</VirtualHost>\n')),(0,o.kt)("h2",{id:"with-ssl-termination"},"With SSL termination"),(0,o.kt)("p",null,"This configuration builds on the one above and uses Firezone's auto-generated\nself-signed certificates."),(0,o.kt)("pre",null,(0,o.kt)("code",{parentName:"pre",className:"language-conf"},'LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so\nLoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so\nLoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so\nLoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so\nLoadModule ssl_module /usr/lib/apache2/modules/mod_ssl.so\nLoadModule headers_module /usr/lib/apache2/modules/mod_headers.so\nListen 443\n<VirtualHost *:443>\n        ServerName <server-name>\n        RequestHeader set X-Forwarded-Proto "https"\n        ProxyPassReverse "/" "http://127.0.0.1:13000/"\n        ProxyPass "/" "http://127.0.0.1:13000/"\n        RewriteEngine on\n        RewriteCond %{HTTP:Upgrade} websocket [NC]\n        RewriteCond %{HTTP:Connection} upgrade [NC]\n        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]\n        SSLEngine On\n        SSLCertificateFile "/var/opt/firezone/ssl/ca/acme-test.firez.one.crt"\n        SSLCertificateKeyFile "/var/opt/firezone/ssl/ca/acme-test.firez.one.key"\n</VirtualHost>\n')))}d.isMDXComponent=!0}}]);