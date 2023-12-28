import {
  createContext,
  useContext,
  ComponentType,
  FunctionComponent,
  ReactNode,
} from "react";
import mixpanel, { Mixpanel, Config } from "mixpanel-browser";

interface WithMixPanel {
  mixpanel: Mixpanel;
}

const MixPanelContext = createContext({} as WithMixPanel);
const useMixPanel = () => useContext(MixPanelContext);

function withMixpanel<T>(
  Component: ComponentType<T>
): FunctionComponent<T & WithMixPanel> {
  return (props: T) => <Component {...props} mixpanel={mixpanel} />;
}

const MixPanelProvider = ({
  children,
  token = "",
  config = {},
}: {
  children: ReactNode;
  token?: string;
  config?: Partial<Config>;
}) => {
  if (!!token) {
    mixpanel.init(token, config);
  }
  return (
    <MixPanelContext.Provider value={{ mixpanel }}>
      {children}
    </MixPanelContext.Provider>
  );
};

export { useMixPanel, withMixpanel, MixPanelContext };
export default MixPanelProvider;
