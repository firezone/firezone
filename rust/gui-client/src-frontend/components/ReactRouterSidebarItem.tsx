import React from "react";
import type { FC, ComponentProps } from "react";
import { useNavigate, useLocation } from "react-router";
import { SidebarItem } from "flowbite-react";

export default function ReactRouterSidebarItem({
  href,
  icon,
  children,
}: {
  href: string;
  icon: FC<ComponentProps<"svg">>;
  children: React.ReactNode;
}) {
  const location = useLocation();
  const navigate = useNavigate();

  // Custom navigation handler for SidebarItems to avoid full page reloads
  const handleClick = (event: React.MouseEvent<HTMLDivElement>) => {
    event.preventDefault();
    const target = event.currentTarget;
    const href = target.getAttribute("href");
    if (href) {
      navigate(href);
    }
  };

  return (
    <SidebarItem
      active={location.pathname.startsWith(href)}
      href={href}
      icon={icon}
      onClick={handleClick}
    >
      {children}
    </SidebarItem>
  );
}
