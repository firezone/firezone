import React from "react";
import { useLocation, useNavigate } from "react-router";
import RemixIcon, { RemixIconName } from "./RemixIcon";

interface Props {
  href: string;
  icon: RemixIconName;
  children: React.ReactNode;
}

export default function ReactRouterSidebarItem({
  href,
  icon: Icon,
  children,
}: Props) {
  const location = useLocation();
  const navigate = useNavigate();
  const active = location.pathname.startsWith(href);

  const handleClick = (event: React.MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault();
    navigate(href);
  };

  return (
    <a
      aria-current={active ? "page" : undefined}
      className={`nav-item ${active ? "nav-item-active" : ""}`}
      href={href}
      onClick={handleClick}
    >
      <RemixIcon className="h-4 w-4" name={Icon} />
      <span>{children}</span>
    </a>
  );
}
