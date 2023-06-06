// This wraps all Flowbite components with a "use client" directive as a
// workaround for the issue described here:
// https://github.com/themesberg/flowbite-react/issues/448
"use client";
import {
  Alert,
  Tabs
} from "flowbite-react";

const TabsGroup = Tabs.Group;
const TabsItem = Tabs.Item;

export {
  Alert,
  TabsGroup,
  TabsItem,
};
