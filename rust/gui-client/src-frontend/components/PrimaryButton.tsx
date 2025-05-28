import { Button, ButtonProps } from "flowbite-react";
import React from "react";

export default function PrimaryButton({
  children,
  ...props
}: React.PropsWithChildren<ButtonProps>) {
  return (
    <Button
      clearTheme={{ color: true }}
      className="bg-accent-450 hover:bg-accent-700 text-white font-medium rounded-md text-md px-5 py-1.5"
      {...props}
    >
      {children}
    </Button>
  );
}
