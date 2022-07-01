"use strict";(self.webpackChunknew_docs=self.webpackChunknew_docs||[]).push([[9],{3905:function(e,r,t){t.d(r,{Zo:function(){return c},kt:function(){return d}});var n=t(7294);function o(e,r,t){return r in e?Object.defineProperty(e,r,{value:t,enumerable:!0,configurable:!0,writable:!0}):e[r]=t,e}function i(e,r){var t=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);r&&(n=n.filter((function(r){return Object.getOwnPropertyDescriptor(e,r).enumerable}))),t.push.apply(t,n)}return t}function l(e){for(var r=1;r<arguments.length;r++){var t=null!=arguments[r]?arguments[r]:{};r%2?i(Object(t),!0).forEach((function(r){o(e,r,t[r])})):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(t)):i(Object(t)).forEach((function(r){Object.defineProperty(e,r,Object.getOwnPropertyDescriptor(t,r))}))}return e}function s(e,r){if(null==e)return{};var t,n,o=function(e,r){if(null==e)return{};var t,n,o={},i=Object.keys(e);for(n=0;n<i.length;n++)t=i[n],r.indexOf(t)>=0||(o[t]=e[t]);return o}(e,r);if(Object.getOwnPropertySymbols){var i=Object.getOwnPropertySymbols(e);for(n=0;n<i.length;n++)t=i[n],r.indexOf(t)>=0||Object.prototype.propertyIsEnumerable.call(e,t)&&(o[t]=e[t])}return o}var u=n.createContext({}),a=function(e){var r=n.useContext(u),t=r;return e&&(t="function"==typeof e?e(r):l(l({},r),e)),t},c=function(e){var r=a(e.components);return n.createElement(u.Provider,{value:r},e.children)},f={inlineCode:"code",wrapper:function(e){var r=e.children;return n.createElement(n.Fragment,{},r)}},p=n.forwardRef((function(e,r){var t=e.components,o=e.mdxType,i=e.originalType,u=e.parentName,c=s(e,["components","mdxType","originalType","parentName"]),p=a(t),d=o,m=p["".concat(u,".").concat(d)]||p[d]||f[d]||i;return t?n.createElement(m,l(l({ref:r},c),{},{components:t})):n.createElement(m,l({ref:r},c))}));function d(e,r){var t=arguments,o=r&&r.mdxType;if("string"==typeof e||o){var i=t.length,l=new Array(i);l[0]=p;var s={};for(var u in r)hasOwnProperty.call(r,u)&&(s[u]=r[u]);s.originalType=e,s.mdxType="string"==typeof e?e:o,l[1]=s;for(var a=2;a<i;a++)l[a]=t[a];return n.createElement.apply(null,l)}return n.createElement.apply(null,t)}p.displayName="MDXCreateElement"},3070:function(e,r,t){t.r(r),t.d(r,{assets:function(){return c},contentTitle:function(){return u},default:function(){return d},frontMatter:function(){return s},metadata:function(){return a},toc:function(){return f}});var n=t(7462),o=t(3366),i=(t(7294),t(3905)),l=["components"],s={layout:"default",title:"Firewall Rules",nav_order:3,parent:"User Guides",description:"This section contains details on how to configure the firewall rules for Firezone.\n"},u=void 0,a={unversionedId:"user-guides/firewall-rules",id:"user-guides/firewall-rules",title:"Firewall Rules",description:"This section contains details on how to configure the firewall rules for Firezone.\n",source:"@site/docs/user-guides/firewall-rules.md",sourceDirName:"user-guides",slug:"/user-guides/firewall-rules",permalink:"/user-guides/firewall-rules",draft:!1,editUrl:"https://github.com/firezone/firezone/docs/user-guides/firewall-rules.md",tags:[],version:"current",frontMatter:{layout:"default",title:"Firewall Rules",nav_order:3,parent:"User Guides",description:"This section contains details on how to configure the firewall rules for Firezone.\n"},sidebar:"tutorialSidebar",previous:{title:"Client Instructions",permalink:"/user-guides/client-instructions"},next:{title:"Reverse Tunnel",permalink:"/user-guides/reverse-tunnel"}},c={},f=[],p={toc:f};function d(e){var r=e.components,t=(0,o.Z)(e,l);return(0,i.kt)("wrapper",(0,n.Z)({},p,t,{components:r,mdxType:"MDXLayout"}),(0,i.kt)("p",null,"Firezone supports egress filtering controls to explicitly DROP or ACCEPT packets\nvia the kernel's netfilter system. By default, all traffic is allowed."),(0,i.kt)("p",null,"The Allowlist and Denylist support both IPv4 and IPv6 CIDRs and IP addresses."),(0,i.kt)("p",null,(0,i.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/153467657-fe287f2c-feab-41f5-8852-6cefd9d5d6b5.png",alt:"firewall rules"})))}d.isMDXComponent=!0}}]);