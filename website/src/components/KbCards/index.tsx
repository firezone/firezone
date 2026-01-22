import { Route } from "next";
import Link from "next/link";

export function KbCard({
  title,
  href,
  logo,
  children,
}: {
  title: string;
  href: URL | Route<string>;
  logo: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="flex flex-col p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
    >
      <h3 className="text-neutral-800 text-xl font-semibold tracking-tight mb-12">
        {title}
      </h3>
      {logo}
      <div className="mt-auto tracking-tight">{children}</div>
    </Link>
  );
}

export function KbCards({ children }: { children: React.ReactNode }) {
  return (
    <div className="not-format grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-3">
      {children}
    </div>
  );
}
