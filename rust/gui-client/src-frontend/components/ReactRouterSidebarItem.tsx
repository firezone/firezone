import React from "react";
import { useNavigate, useLocation } from "react-router";
import RemixIcon, { RemixIconName } from "./RemixIcon";

export default function ReactRouterSidebarItem({
  href,
  icon,
  children,
}: {
  href: string;
  icon: RemixIconName;
  children: React.ReactNode;
}) {
  const location = useLocation();
  const navigate = useNavigate();

  // Custom navigation handler for SidebarItems to avoid full page reloads
  const handleClick = (event: React.MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault();
    navigate(href);
  };

  return (
    <a
      aria-current={location.pathname.startsWith(href) ? "page" : undefined}
      className={`nav-item ${
        location.pathname.startsWith(href) ? "nav-item-active" : ""
      }`}
      href={href}
      onClick={handleClick}
    >
      <RemixIcon className="h-4 w-4" name={icon} />
      <span>{children}</span>
    </a>
  );
}
