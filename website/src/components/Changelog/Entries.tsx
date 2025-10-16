import React from "react";
import Link from "next/link";
import Unreleased from "./Unreleased";

export type DownloadLink = {
  title: string;
  href: string;
};

function Latest({
  downloadLinks,
  title,
  version,
  date,
  children,
}: {
  downloadLinks: DownloadLink[];
  title: string;
  version: string;
  date: Date;
  children: React.ReactNode;
}) {
  const options: Intl.DateTimeFormatOptions = {
    timeZone: "UTC",
    year: "numeric",
    month: "long",
    day: "numeric",
  };
  const utcDateString = date.toLocaleDateString("en-US", options);
  return (
    <>
      <h3 className="text-lg md:text-xl xl:text-2xl font-semibold tracking-tight mb-4 md:mb-6 xl:mb-8  text-neutral-800">
        Latest {title} version
      </h3>
      <div className="text-sm md:text-lg text-neutral-800 mb-8 md:mb-10 xl:mb-12">
        <p>
          Version: <span className="font-semibold">{version}</span>
        </p>
        <p className="mb-4 md:mb-6 xl:mb-8">
          Released:{" "}
          <span className="font-semibold">
            <time dateTime={date.toDateString()}>{utcDateString}</time>
          </span>
        </p>
        <ul className="mb-4 md:mb-6 xl:mb-8">
          {downloadLinks.map((link) => (
            <li key={link.href}>
              <Link
                key={link.href}
                href={{ pathname: link.href.replace(":version", version) }}
                className="hover:no-underline underline text-accent-500 mr-2"
              >
                {link.title}
              </Link>
            </li>
          ))}
        </ul>
        {children}
      </div>
    </>
  );
}

function Previous({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <>
      <h3 className="text-lg md:text-xl xl:text-2xl font-semibold tracking-tight mb-4 md:mb-6 xl:mb-8 text-neutral-800">
        Previous {title} versions
      </h3>
      <table className="w-full text-left">
        <thead className="text-neutral-800 bg-neutral-100 uppercase">
          <tr>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Version
            </th>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Date
            </th>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Description
            </th>
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </>
  );
}

type EntryProps = {
  version: string;
  date: Date;
  children: React.ReactNode;
};

export default function Entries({
  downloadLinks,
  title,
  children,
}: {
  downloadLinks: DownloadLink[];
  title: string;
  children: React.ReactNode;
}) {
  const childrenArray = React.Children.toArray(children)
    .filter((child): child is React.ReactElement<EntryProps> =>
      React.isValidElement(child)
    )
    .filter((child) => child.type != Unreleased);

  const firstEntry = childrenArray[0];
  const previousEntries = childrenArray.slice(1);

  const { version, date, children: firstEntryChildren } = firstEntry.props;

  return (
    <div className="relative overflow-x-auto p-4 md:p-6 xl:p-8">
      <Latest
        downloadLinks={downloadLinks}
        title={title}
        version={version}
        date={date}
      >
        {firstEntryChildren}
      </Latest>
      <Previous title={title}>{previousEntries}</Previous>
    </div>
  );
}
