"use client";

import React, { ReactNode, useEffect } from "react";

interface ErrorBoundaryProps {
  children: ReactNode;
}

const ErrorBoundary: React.FC<ErrorBoundaryProps> = ({ children }) => {
  useEffect(() => {
    const handleErrors = (event: ErrorEvent) => {
      console.error("ErrorBoundary caught an error", event.error);
    };

    window.addEventListener("error", handleErrors);

    return () => {
      window.removeEventListener("error", handleErrors);
    };
  }, []);

  return <>{children}</>;
};

export default ErrorBoundary;
