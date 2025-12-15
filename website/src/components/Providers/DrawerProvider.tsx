"use client";

import {
  createContext,
  useContext,
  useState,
  useEffect,
  ReactNode,
} from "react";

interface DrawerContextType {
  isShown: boolean;
  toggle: () => void;
}

const DrawerContext = createContext<DrawerContextType | undefined>(undefined);

interface DrawerProviderProps {
  children: ReactNode;
}

export const DrawerProvider: React.FC<DrawerProviderProps> = ({ children }) => {
  const [isShown, setIsShown] = useState<boolean>(false);
  const [manualToggle, setManualToggle] = useState<boolean>(false);

  useEffect(() => {
    const getIsMediumScreen = () => window.innerWidth >= 768;

    const handleResize = () => {
      setIsShown(getIsMediumScreen() || manualToggle);
    };

    // Set initial value on mount
    handleResize();

    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, [manualToggle]);

  const toggle = () => {
    setIsShown((prevState) => !prevState);
    setManualToggle((prevState) => !prevState);
  };

  return (
    <DrawerContext.Provider value={{ isShown, toggle }}>
      {children}
    </DrawerContext.Provider>
  );
};

export const useDrawer = (): DrawerContextType => {
  const context = useContext(DrawerContext);
  if (!context) {
    throw new Error("useDrawer must be used within a DrawerProvider");
  }
  return context;
};
