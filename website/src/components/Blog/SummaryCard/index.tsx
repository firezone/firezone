import ActionLink from "@/components/ActionLink";
import Link from "next/link";
import { Route } from "next";

import Image from "next/image";

export default function SummaryCard({
  children,
  date,
  href,
  title,
  authorName,
  authorAvatarSrc,
  type,
}: {
  children: React.ReactNode;
  date: string;
  href: Route<string>;
  title: string;
  authorName: string;
  authorAvatarSrc: string;
  type: string;
}) {
  return (
    <article className="p-6">
      <div className="flex justify-between items-center mb-5">
        <span className="text-neutral-500 font-semibold text-xs inline-flex items-center">
          {type.toUpperCase()}
        </span>
        <span className="text-sm font-semibold">{date}</span>
      </div>
      <h2 className="mb-2 text-2xl font-bold tracking-tight text-neutral-800 ">
        {title}
      </h2>
      <div className="mb-5 font-medium text-neutral-800 ">{children}</div>
      <div className="flex justify-between items-center">
        <div className="flex items-center space-x-4">
          <Image
            width={28}
            height={28}
            className="w-7 h-7 rounded-full"
            src={authorAvatarSrc}
            alt={authorName + " avatar"}
          />
          <span className="font-medium ">{authorName}</span>
        </div>
        <ActionLink
          href={href}
          className="group inline-flex items-center font-medium text-accent-500 underline hover:no-underline"
        >
          Read more
        </ActionLink>
      </div>
    </article>
  );
}
