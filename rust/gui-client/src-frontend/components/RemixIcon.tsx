import React from "react";
import home from "remixicon/icons/Buildings/home-line.svg";
import palette from "remixicon/icons/Design/palette-line.svg";
import computer from "remixicon/icons/Device/computer-line.svg";
import database from "remixicon/icons/Device/database-2-line.svg";
import server from "remixicon/icons/Device/server-line.svg";
import certificate from "remixicon/icons/Document/certificate-line.svg";
import copy from "remixicon/icons/Document/file-copy-line.svg";
import code from "remixicon/icons/Development/code-s-slash-line.svg";
import arrowDown from "remixicon/icons/Arrows/arrow-down-s-line.svg";
import alert from "remixicon/icons/System/alert-line.svg";
import check from "remixicon/icons/System/checkbox-circle-line.svg";
import close from "remixicon/icons/System/close-line.svg";
import deleteBin from "remixicon/icons/System/delete-bin-line.svg";
import externalLink from "remixicon/icons/System/external-link-line.svg";
import information from "remixicon/icons/System/information-line.svg";
import lock from "remixicon/icons/System/lock-line.svg";
import search from "remixicon/icons/System/search-line.svg";
import settings from "remixicon/icons/System/settings-3-line.svg";
import shareForward from "remixicon/icons/System/share-forward-line.svg";
import starFill from "remixicon/icons/System/star-fill.svg";
import star from "remixicon/icons/System/star-line.svg";

const icons = {
  alert,
  "arrow-down": arrowDown,
  certificate,
  check,
  close,
  code,
  computer,
  copy,
  database,
  "delete-bin": deleteBin,
  "external-link": externalLink,
  home,
  information,
  lock,
  palette,
  search,
  server,
  settings,
  "share-forward": shareForward,
  star,
  "star-fill": starFill,
} as const;

export type RemixIconName = keyof typeof icons;

interface RemixIconProps {
  className?: string;
  name: RemixIconName;
}

export default function RemixIcon({ className = "", name }: RemixIconProps) {
  const source = `url("${icons[name]}")`;

  return (
    <span
      aria-hidden="true"
      className={`inline-block shrink-0 bg-current align-middle ${className}`}
      style={{
        maskImage: source,
        maskPosition: "center",
        maskRepeat: "no-repeat",
        maskSize: "contain",
        WebkitMaskImage: source,
        WebkitMaskPosition: "center",
        WebkitMaskRepeat: "no-repeat",
        WebkitMaskSize: "contain",
      }}
    />
  );
}
