"use strict";(self.webpackChunknew_docs=self.webpackChunknew_docs||[]).push([[26],{3905:function(e,t,n){n.d(t,{Zo:function(){return u},kt:function(){return m}});var i=n(7294);function a(e,t,n){return t in e?Object.defineProperty(e,t,{value:n,enumerable:!0,configurable:!0,writable:!0}):e[t]=n,e}function r(e,t){var n=Object.keys(e);if(Object.getOwnPropertySymbols){var i=Object.getOwnPropertySymbols(e);t&&(i=i.filter((function(t){return Object.getOwnPropertyDescriptor(e,t).enumerable}))),n.push.apply(n,i)}return n}function o(e){for(var t=1;t<arguments.length;t++){var n=null!=arguments[t]?arguments[t]:{};t%2?r(Object(n),!0).forEach((function(t){a(e,t,n[t])})):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(n)):r(Object(n)).forEach((function(t){Object.defineProperty(e,t,Object.getOwnPropertyDescriptor(n,t))}))}return e}function l(e,t){if(null==e)return{};var n,i,a=function(e,t){if(null==e)return{};var n,i,a={},r=Object.keys(e);for(i=0;i<r.length;i++)n=r[i],t.indexOf(n)>=0||(a[n]=e[n]);return a}(e,t);if(Object.getOwnPropertySymbols){var r=Object.getOwnPropertySymbols(e);for(i=0;i<r.length;i++)n=r[i],t.indexOf(n)>=0||Object.prototype.propertyIsEnumerable.call(e,n)&&(a[n]=e[n])}return a}var s=i.createContext({}),c=function(e){var t=i.useContext(s),n=t;return e&&(n="function"==typeof e?e(t):o(o({},t),e)),n},u=function(e){var t=c(e.components);return i.createElement(s.Provider,{value:t},e.children)},p={inlineCode:"code",wrapper:function(e){var t=e.children;return i.createElement(i.Fragment,{},t)}},d=i.forwardRef((function(e,t){var n=e.components,a=e.mdxType,r=e.originalType,s=e.parentName,u=l(e,["components","mdxType","originalType","parentName"]),d=c(n),m=a,f=d["".concat(s,".").concat(m)]||d[m]||p[m]||r;return n?i.createElement(f,o(o({ref:t},u),{},{components:n})):i.createElement(f,o({ref:t},u))}));function m(e,t){var n=arguments,a=t&&t.mdxType;if("string"==typeof e||a){var r=n.length,o=new Array(r);o[0]=d;var l={};for(var s in t)hasOwnProperty.call(t,s)&&(l[s]=t[s]);l.originalType=e,l.mdxType="string"==typeof e?e:a,o[1]=l;for(var c=2;c<r;c++)o[c]=n[c];return i.createElement.apply(null,o)}return i.createElement.apply(null,n)}d.displayName="MDXCreateElement"},1632:function(e,t,n){n.r(t),n.d(t,{assets:function(){return u},contentTitle:function(){return s},default:function(){return m},frontMatter:function(){return l},metadata:function(){return c},toc:function(){return p}});var i=n(7462),a=n(3366),r=(n(7294),n(3905)),o=["components"],l={layout:"default",title:"Client Instructions",nav_order:5,parent:"User Guides",description:"Install the WireGuard client and import the configuration file generated by firezone to establish a VPN session.\n"},s=void 0,c={unversionedId:"user-guides/client-instructions",id:"user-guides/client-instructions",title:"Client Instructions",description:"Install the WireGuard client and import the configuration file generated by firezone to establish a VPN session.\n",source:"@site/docs/user-guides/client-instructions.md",sourceDirName:"user-guides",slug:"/user-guides/client-instructions",permalink:"/user-guides/client-instructions",draft:!1,editUrl:"https://github.com/firezone/firezone/docs/user-guides/client-instructions.md",tags:[],version:"current",frontMatter:{layout:"default",title:"Client Instructions",nav_order:5,parent:"User Guides",description:"Install the WireGuard client and import the configuration file generated by firezone to establish a VPN session.\n"},sidebar:"tutorialSidebar",previous:{title:"Add Users",permalink:"/user-guides/add-users"},next:{title:"Firewall Rules",permalink:"/user-guides/firewall-rules"}},u={},p=[{value:"Install and Setup",id:"install-and-setup",level:2},{value:"Step 1 - Install the native WireGuard client",id:"step-1---install-the-native-wireguard-client",level:3},{value:"Step 2 - Download the device config file",id:"step-2---download-the-device-config-file",level:3},{value:"Step 3 - Add the config to the client",id:"step-3---add-the-config-to-the-client",level:3},{value:"Re-authenticating your session",id:"re-authenticating-your-session",level:2},{value:"Step 1 - Deactivate VPN session",id:"step-1---deactivate-vpn-session",level:3},{value:"Step 2 - Re-authenticate",id:"step-2---re-authenticate",level:3},{value:"Step 3 - Activate VPN session",id:"step-3---activate-vpn-session",level:3},{value:"Linux - Network Manager",id:"linux---network-manager",level:2},{value:"Step 1 - Install the WireGuard Tools",id:"step-1---install-the-wireguard-tools",level:3},{value:"Step 2 - Download configuration",id:"step-2---download-configuration",level:3},{value:"Step 3 - Import configuration",id:"step-3---import-configuration",level:3},{value:"Step 4 - Connect/disconnect",id:"step-4---connectdisconnect",level:3},{value:"Auto Connection",id:"auto-connection",level:3}],d={toc:p};function m(e){var t=e.components,n=(0,a.Z)(e,o);return(0,r.kt)("wrapper",(0,i.Z)({},d,n,{components:t,mdxType:"MDXLayout"}),(0,r.kt)("h2",{id:"install-and-setup"},"Install and Setup"),(0,r.kt)("p",null,"Follow this guide to establish a VPN session\nthrough the WireGuard native client."),(0,r.kt)("h3",{id:"step-1---install-the-native-wireguard-client"},"Step 1 - Install the native WireGuard client"),(0,r.kt)("p",null,"Firezone is compatible with the official WireGuard clients found here:"),(0,r.kt)("ul",null,(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("a",{parentName:"li",href:"https://itunes.apple.com/us/app/wireguard/id1451685025"},"MacOS")),(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("a",{parentName:"li",href:"https://download.wireguard.com/windows-client/wireguard-installer.exe"},"Windows")),(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("a",{parentName:"li",href:"https://itunes.apple.com/us/app/wireguard/id1441195209"},"iOS")),(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("a",{parentName:"li",href:"https://play.google.com/store/apps/details?id=com.wireguard.android"},"Android"))),(0,r.kt)("p",null,"For operating systems not listed above see the Official WireGuard site: ",(0,r.kt)("a",{parentName:"p",href:"https://www.wireguard.com/install/"},"\nhttps://www.wireguard.com/install/"),"."),(0,r.kt)("h3",{id:"step-2---download-the-device-config-file"},"Step 2 - Download the device config file"),(0,r.kt)("p",null,"The device config file can either be obtained from your Firezone administrator\nor self-generated via the Firezone portal."),(0,r.kt)("p",null,"To self generate a device config file, visit the domain provided by your Firezone\nadministrator. This URL will be specific to your company\n(in this example it is ",(0,r.kt)("inlineCode",{parentName:"p"},"https://firezone.example.com"),")"),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/156855886-5a4a0da7-065c-4ec1-af33-583dff4dbb72.gif",alt:"Firezone Okta SSO Login"})),(0,r.kt)("h3",{id:"step-3---add-the-config-to-the-client"},"Step 3 - Add the config to the client"),(0,r.kt)("p",null,"Open the WireGuard client and import the ",(0,r.kt)("inlineCode",{parentName:"p"},".conf")," file.\nActivate the VPN session by toggling the ",(0,r.kt)("inlineCode",{parentName:"p"},"Activate")," switch."),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/156859686-41755bf7-a9ad-42ec-af5e-9f0734d962db.gif",alt:"Activate Tunnel"})),(0,r.kt)("h2",{id:"re-authenticating-your-session"},"Re-authenticating your session"),(0,r.kt)("p",null,"If your network admin has required periodic authentication to maintain your VPN session,\nfollow the steps below. You will need:"),(0,r.kt)("ul",null,(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("strong",{parentName:"li"},"URL of the Firezone portal"),": Ask your Network Admin for the link."),(0,r.kt)("li",{parentName:"ul"},(0,r.kt)("strong",{parentName:"li"},"Credentials"),": Your username and password should be provided by your Network\nAdmin. If your company is using a Single Sign On provider (like Google or Okta),\nthe Firezone portal will prompt you to authenticate via that provider.")),(0,r.kt)("h3",{id:"step-1---deactivate-vpn-session"},"Step 1 - Deactivate VPN session"),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/156859259-a3d386ce-b304-4caa-96e6-a8e7ca96d098.png",alt:"WireGuard Deactivate"})),(0,r.kt)("h3",{id:"step-2---re-authenticate"},"Step 2 - Re-authenticate"),(0,r.kt)("p",null,"Visit the URL of your Firezone portal and sign in using credentials provided by your\nnetwork admin. If you are already logged into the portal,\nclick the ",(0,r.kt)("inlineCode",{parentName:"p"},"Reauthenticate")," button, then sign in again."),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/155812962-9b8688c1-00af-41e4-96c3-8fb52f840aed.gif",alt:"re-authenticate"})),(0,r.kt)("h3",{id:"step-3---activate-vpn-session"},"Step 3 - Activate VPN session"),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/156859636-fde95fc5-5b9c-4697-9108-2f277ed3fbef.png",alt:"Activate Session"})),(0,r.kt)("h2",{id:"linux---network-manager"},"Linux - Network Manager"),(0,r.kt)("p",null,"The following steps can be used on Linux devices to import the WireGuard\nconfiguration profile using Network Manager CLI (",(0,r.kt)("inlineCode",{parentName:"p"},"nmcli"),")."),(0,r.kt)("p",null,"Note: Importing the configuration file using the Network Manager GUI may fail\nwith the following error if the profile has IPv6 support enabled:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-text"},'ipv6.method: method "auto" is not supported for WireGuard\n')),(0,r.kt)("h3",{id:"step-1---install-the-wireguard-tools"},"Step 1 - Install the WireGuard Tools"),(0,r.kt)("p",null,"The WireGuard userspace tools need to be installed. For most Linux\ndistributions this will be a package named ",(0,r.kt)("inlineCode",{parentName:"p"},"wireguard")," or ",(0,r.kt)("inlineCode",{parentName:"p"},"wireguard-tools"),"."),(0,r.kt)("p",null,"For Debian/Ubuntu:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"sudo apt install wireguard\n")),(0,r.kt)("p",null,"For Fedora:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"sudo dnf install wireguard-tools\n")),(0,r.kt)("p",null,"For Arch Linux:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"sudo pacman -S wireguard-tools\n")),(0,r.kt)("p",null,"For distributions not listed above see the Official WireGuard site: ",(0,r.kt)("a",{parentName:"p",href:"https://www.wireguard.com/install/"},"\nhttps://www.wireguard.com/install/"),"."),(0,r.kt)("h3",{id:"step-2---download-configuration"},"Step 2 - Download configuration"),(0,r.kt)("p",null,"The device config file can either be obtained from your Firezone administrator\nor self-generated via the Firezone portal."),(0,r.kt)("p",null,"To self generate a device config file, visit the domain provided by your Firezone\nadministrator. This URL will be specific to your company\n(in this example it is ",(0,r.kt)("inlineCode",{parentName:"p"},"https://firezone.example.com"),")"),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/156855886-5a4a0da7-065c-4ec1-af33-583dff4dbb72.gif",alt:"Firezone Okta SSO Login"}),'{:width="600"}'),(0,r.kt)("h3",{id:"step-3---import-configuration"},"Step 3 - Import configuration"),(0,r.kt)("p",null,"Using ",(0,r.kt)("inlineCode",{parentName:"p"},"nmcli"),", import the downloaded configuration file:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"sudo nmcli connection import type wireguard file /path/to/configuration.conf\n")),(0,r.kt)("p",null,"Note: The WireGuard connection/interface will match the name of the configuration\nfile. If required, the connection can be renamed after import:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"nmcli connection modify [old name] connection.id [new name]\n")),(0,r.kt)("h3",{id:"step-4---connectdisconnect"},"Step 4 - Connect/disconnect"),(0,r.kt)("p",null,"To connect to the VPN via the command line:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"nmcli connection up [vpn name]\n")),(0,r.kt)("p",null,"To disconnect:"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"nmcli connection down [vpn name]\n")),(0,r.kt)("p",null,"If using a GUI, the relevant Network Manager applet can also be used to control\nthe connection."),(0,r.kt)("h3",{id:"auto-connection"},"Auto Connection"),(0,r.kt)("p",null,"The VPN connection can be set to automatically connect by setting the ",(0,r.kt)("inlineCode",{parentName:"p"},"autoconnect"),"\noption to ",(0,r.kt)("inlineCode",{parentName:"p"},"yes"),":"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"nmcli connection modify [vpn name] connection.autoconnect yes\n")),(0,r.kt)("p",null,"To disable the automatic connection set it back to ",(0,r.kt)("inlineCode",{parentName:"p"},"no"),":"),(0,r.kt)("pre",null,(0,r.kt)("code",{parentName:"pre",className:"language-shell"},"nmcli connection modify [vpn name] connection.autoconnect no\n")))}m.isMDXComponent=!0}}]);