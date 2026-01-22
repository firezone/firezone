"use client";
import {
  HiOutlineInformationCircle,
  HiOutlineExclamationCircle,
  HiOutlineExclamationTriangle,
} from "react-icons/hi2";

export default function Alert({
  children,
  color,
}: {
  children: React.ReactNode;
  color: string;
}) {
  switch (color) {
    case "info":
      return (
        <div className="text-sm mb-4 px-3 py-3 flex items-center rounded-sm border bg-neutral-100 text-neutral-800 border-neutral-200">
          <HiOutlineInformationCircle className="flex-none w-5 h-5 mr-2" />
          {children}
        </div>
      );
    case "warning":
      return (
        <div className="text-sm mb-4 px-3 py-3 flex items-center rounded-sm border bg-accent-100 text-accent-800 border-accent-200">
          <HiOutlineExclamationCircle className="flex-none w-5 h-5 mr-2" />
          {children}
        </div>
      );
    case "danger":
      return (
        <div className="text-sm mb-4 px-3 flex items-center rounded-sm border bg-primary-100 text-primary-800 border-primary-200">
          <HiOutlineExclamationTriangle className="flex-none w-5 h-5 mr-2" />
          {children}
        </div>
      );
  }
}
