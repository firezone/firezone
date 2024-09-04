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
  src,
}: {
  children: React.ReactNode;
  date: string;
  href: URL | Route<string>;
  title: string;
  authorName: string;
  authorAvatarSrc: string;
  type: string;
  src?: string;
}) {
  return (
    <Link href={href}>
      <article className="py-6 px-4 sm:px-6 md:px-8 lg:px-10 flex gap-12 hover:bg-neutral-100 bg-white mt-2 rounded-2xl cursor-pointer">
        <div className="w-full">
          <div className="flex justify-between items-center mb-2">
            <span className="text-primary-450 font-semibold text-sm inline-flex items-center">
              {type.toUpperCase()}
            </span>
          </div>
          <h2 className="mb-3 text-2xl font-bold tracking-tight text-neutral-800 ">
            {title}
          </h2>
          <div className="mb-6 font-regular text-neutral-800 ">{children}</div>
          <div className="flex gap-3 items-center text-sm">
            <div className="flex items-center space-x-3">
              <Image
                width={28}
                height={28}
                className="w-7 h-7 rounded-full"
                src={authorAvatarSrc}
                alt={authorName + " avatar"}
              />
              <span className="font-semibold">{authorName}</span>
            </div>
            <span className="font-semibold text-neutral-600">{date}</span>
          </div>
        </div>
        {src && (
          <div className="rounded-lg overflow-hidden max-h-[120px] w-[240px]">
            <Image
              src={src}
              width={200}
              height={200}
              alt="Article Image"
              className="object-cover rounded-lg object-center"
            />
          </div>
        )}
      </article>
    </Link>
  );
}
