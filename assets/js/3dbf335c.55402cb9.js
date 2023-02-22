"use strict";(self.webpackChunkfirezone_docs=self.webpackChunkfirezone_docs||[]).push([[6771],{3905:(t,e,n)=>{n.d(e,{Zo:()=>u,kt:()=>g});var a=n(7294);function r(t,e,n){return e in t?Object.defineProperty(t,e,{value:n,enumerable:!0,configurable:!0,writable:!0}):t[e]=n,t}function i(t,e){var n=Object.keys(t);if(Object.getOwnPropertySymbols){var a=Object.getOwnPropertySymbols(t);e&&(a=a.filter((function(e){return Object.getOwnPropertyDescriptor(t,e).enumerable}))),n.push.apply(n,a)}return n}function o(t){for(var e=1;e<arguments.length;e++){var n=null!=arguments[e]?arguments[e]:{};e%2?i(Object(n),!0).forEach((function(e){r(t,e,n[e])})):Object.getOwnPropertyDescriptors?Object.defineProperties(t,Object.getOwnPropertyDescriptors(n)):i(Object(n)).forEach((function(e){Object.defineProperty(t,e,Object.getOwnPropertyDescriptor(n,e))}))}return t}function l(t,e){if(null==t)return{};var n,a,r=function(t,e){if(null==t)return{};var n,a,r={},i=Object.keys(t);for(a=0;a<i.length;a++)n=i[a],e.indexOf(n)>=0||(r[n]=t[n]);return r}(t,e);if(Object.getOwnPropertySymbols){var i=Object.getOwnPropertySymbols(t);for(a=0;a<i.length;a++)n=i[a],e.indexOf(n)>=0||Object.prototype.propertyIsEnumerable.call(t,n)&&(r[n]=t[n])}return r}var s=a.createContext({}),p=function(t){var e=a.useContext(s),n=e;return t&&(n="function"==typeof t?t(e):o(o({},e),t)),n},u=function(t){var e=p(t.components);return a.createElement(s.Provider,{value:e},t.children)},d="mdxType",c={inlineCode:"code",wrapper:function(t){var e=t.children;return a.createElement(a.Fragment,{},e)}},m=a.forwardRef((function(t,e){var n=t.components,r=t.mdxType,i=t.originalType,s=t.parentName,u=l(t,["components","mdxType","originalType","parentName"]),d=p(n),m=r,g=d["".concat(s,".").concat(m)]||d[m]||c[m]||i;return n?a.createElement(g,o(o({ref:e},u),{},{components:n})):a.createElement(g,o({ref:e},u))}));function g(t,e){var n=arguments,r=e&&e.mdxType;if("string"==typeof t||r){var i=n.length,o=new Array(i);o[0]=m;var l={};for(var s in e)hasOwnProperty.call(e,s)&&(l[s]=e[s]);l.originalType=t,l[d]="string"==typeof t?t:r,o[1]=l;for(var p=2;p<i;p++)o[p]=n[p];return a.createElement.apply(null,o)}return a.createElement.apply(null,n)}m.displayName="MDXCreateElement"},4820:(t,e,n)=>{n.r(e),n.d(e,{assets:()=>s,contentTitle:()=>o,default:()=>c,frontMatter:()=>i,metadata:()=>l,toc:()=>p});var a=n(7462),r=(n(7294),n(3905));const i={title:"Okta",sidebar_position:1,description:"Enforce 2FA/MFA using Okta for users of Firezone's WireGuard\xae-based secure access platform. This guide walks through integrating Okta for single sign-on using the SAML 2.0 connector."},o="Enable SSO with Okta (SAML 2.0)",l={unversionedId:"authenticate/saml/okta",id:"authenticate/saml/okta",title:"Okta",description:"Enforce 2FA/MFA using Okta for users of Firezone's WireGuard\xae-based secure access platform. This guide walks through integrating Okta for single sign-on using the SAML 2.0 connector.",source:"@site/docs/authenticate/saml/okta.mdx",sourceDirName:"authenticate/saml",slug:"/authenticate/saml/okta",permalink:"/docs/authenticate/saml/okta",draft:!1,editUrl:"https://github.com/firezone/firezone/blob/master/www/docs/authenticate/saml/okta.mdx",tags:[],version:"current",sidebarPosition:1,frontMatter:{title:"Okta",sidebar_position:1,description:"Enforce 2FA/MFA using Okta for users of Firezone's WireGuard\xae-based secure access platform. This guide walks through integrating Okta for single sign-on using the SAML 2.0 connector."},sidebar:"tutorialSidebar",previous:{title:"SAML 2.0",permalink:"/docs/authenticate/saml/"},next:{title:"Google Workspace",permalink:"/docs/authenticate/saml/google"}},s={},p=[{value:"Step 1: Create a SAML connector",id:"step-1-create-a-saml-connector",level:2},{value:"Step 2: Add SAML identity provider to Firezone",id:"step-2-add-saml-identity-provider-to-firezone",level:2}],u={toc:p},d="wrapper";function c(t){let{components:e,...n}=t;return(0,r.kt)(d,(0,a.Z)({},u,n,{components:e,mdxType:"MDXLayout"}),(0,r.kt)("h1",{id:"enable-sso-with-okta-saml-20"},"Enable SSO with Okta (SAML 2.0)"),(0,r.kt)("admonition",{type:"note"},(0,r.kt)("p",{parentName:"admonition"},"This guide assumes you have completed the prerequisite steps\n(e.g. generate self-signed X.509 certificates) outlined ",(0,r.kt)("a",{parentName:"p",href:"/docs/authenticate/saml#prerequisites"},"here"),".")),(0,r.kt)("p",null,"Firezone supports Single Sign-On (SSO) using Okta through the generic SAML 2.0 connector. This guide will walk you through how to configure the integration."),(0,r.kt)("h2",{id:"step-1-create-a-saml-connector"},"Step 1: Create a SAML connector"),(0,r.kt)("p",null,"In the Okta admin portal, create a new app integration under\nthe Application tab. Select ",(0,r.kt)("inlineCode",{parentName:"p"},"SAML 2.0")," as the authentication method.\nUse the following config values during setup:"),(0,r.kt)("table",null,(0,r.kt)("thead",{parentName:"table"},(0,r.kt)("tr",{parentName:"thead"},(0,r.kt)("th",{parentName:"tr",align:null},"Setting"),(0,r.kt)("th",{parentName:"tr",align:null},"Value"))),(0,r.kt)("tbody",{parentName:"table"},(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"App name"),(0,r.kt)("td",{parentName:"tr",align:null},"Firezone")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"App logo"),(0,r.kt)("td",{parentName:"tr",align:null},(0,r.kt)("a",{parentName:"td",href:"https://user-images.githubusercontent.com/52545545/155907625-a4f6c8c2-3952-488d-b244-3c37400846cf.png"},"save link as"))),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Single sign on URL"),(0,r.kt)("td",{parentName:"tr",align:null},"This is your Firezone ",(0,r.kt)("inlineCode",{parentName:"td"},"EXTERNAL_URL/auth/saml/sp/consume/:config_id")," (e.g., ",(0,r.kt)("inlineCode",{parentName:"td"},"https://firezone.company.com/auth/saml/sp/consume/okta"),").")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Audience (EntityID)"),(0,r.kt)("td",{parentName:"tr",align:null},"This should be the same as your Firezone ",(0,r.kt)("inlineCode",{parentName:"td"},"SAML_ENTITY_ID"),", defaults to ",(0,r.kt)("inlineCode",{parentName:"td"},"urn:firezone.dev:firezone-app"),".")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Name ID format"),(0,r.kt)("td",{parentName:"tr",align:null},"EmailAddress")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Application username"),(0,r.kt)("td",{parentName:"tr",align:null},"Email")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Update application username on"),(0,r.kt)("td",{parentName:"tr",align:null},"Create and update")))),(0,r.kt)("p",null,(0,r.kt)("a",{parentName:"p",href:"https://help.okta.com/oie/en-us/Content/Topics/Apps/Apps_App_Integration_Wizard_SAML.htm"},"Okta's documentation"),"\ncontains additional details on the purpose of each configuration setting."),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/202565311-e98729cf-c7aa-4f8d-965a-55b076177add.png",alt:"Okta SAML"})),(0,r.kt)("p",null,"After creating the SAML connector, visit the ",(0,r.kt)("inlineCode",{parentName:"p"},"View SAML setup instructions")," link in\nthe Sign On tab to download the metadata document. You'll need\nto copy-paste the contents of this document into the Firezone portal in the next step."),(0,r.kt)("h2",{id:"step-2-add-saml-identity-provider-to-firezone"},"Step 2: Add SAML identity provider to Firezone"),(0,r.kt)("p",null,"In the Firezone portal, add a SAML identity provider under the Security tab\nby filling out the following information:"),(0,r.kt)("table",null,(0,r.kt)("thead",{parentName:"table"},(0,r.kt)("tr",{parentName:"thead"},(0,r.kt)("th",{parentName:"tr",align:null},"Setting"),(0,r.kt)("th",{parentName:"tr",align:null},"Value"),(0,r.kt)("th",{parentName:"tr",align:null},"Notes"))),(0,r.kt)("tbody",{parentName:"table"},(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Config ID"),(0,r.kt)("td",{parentName:"tr",align:null},"Okta"),(0,r.kt)("td",{parentName:"tr",align:null},"Used to construct endpoints required in the SAML authentication flow (e.g., receiving assertions, login requests).")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Label"),(0,r.kt)("td",{parentName:"tr",align:null},"Okta"),(0,r.kt)("td",{parentName:"tr",align:null},"Appears on the sign in button for authentication.")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Metadata"),(0,r.kt)("td",{parentName:"tr",align:null},"see note"),(0,r.kt)("td",{parentName:"tr",align:null},"Paste the contents of the SAML metadata document you downloaded in the previous step from Okta.")),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Sign assertions"),(0,r.kt)("td",{parentName:"tr",align:null},"Checked."),(0,r.kt)("td",{parentName:"tr",align:null})),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Sign metadata"),(0,r.kt)("td",{parentName:"tr",align:null},"Checked."),(0,r.kt)("td",{parentName:"tr",align:null})),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Require signed assertions"),(0,r.kt)("td",{parentName:"tr",align:null},"Checked."),(0,r.kt)("td",{parentName:"tr",align:null})),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Required signed envelopes"),(0,r.kt)("td",{parentName:"tr",align:null},"Checked."),(0,r.kt)("td",{parentName:"tr",align:null})),(0,r.kt)("tr",{parentName:"tbody"},(0,r.kt)("td",{parentName:"tr",align:null},"Auto create users"),(0,r.kt)("td",{parentName:"tr",align:null},"Default ",(0,r.kt)("inlineCode",{parentName:"td"},"false")),(0,r.kt)("td",{parentName:"tr",align:null},"Enable this setting to automatically create users when signing in with this connector for the first time. Disable to manually create users.")))),(0,r.kt)("p",null,(0,r.kt)("img",{parentName:"p",src:"https://user-images.githubusercontent.com/52545545/202557861-f7a85df0-d44f-48fd-a980-89e8b0c91503.png",alt:"Firezone SAML"})),(0,r.kt)("p",null,"After saving the SAML config, you should see a ",(0,r.kt)("inlineCode",{parentName:"p"},"Sign in with Okta")," button\non your Firezone portal sign-in page."))}c.isMDXComponent=!0}}]);