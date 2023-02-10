// Import the original mapper
import MDXComponents from "@theme-original/MDXComponents";
import AsciinemaPlayer from '@site/src/components/AsciinemaPlayer';
import InstallBlock from "@site/src/components/InstallBlock";
import AccentBlock from "@site/src/components/AccentBlock";
import Feedback from "@site/src/components/Feedback";
import SignUp from "@site/src/components/SignUp";
import Tabs from "@theme/Tabs";
import TabItem from "@theme/TabItem";

export default {
  // Re-use the default mapping
  ...MDXComponents,
  // Map the "highlight" tag to our <Highlight /> component!
  // `Highlight` will receive all props that were passed to `highlight` in MDX
  AsciinemaPlayer: AsciinemaPlayer,
  InstallBlock: InstallBlock,
  accentblock: AccentBlock,
  feedback: Feedback,
  newsletter: SignUp,
  Tabs: Tabs,
  TabItem: TabItem,
};
