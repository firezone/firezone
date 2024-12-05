import Entry from "./Entry";
import Link from "next/link";

export default function ChangeItem({
  pull,
  children,
}: {
  pull?: string;
  children: React.ReactNode;
}) {
  return (
    <li className="pl-2">
      {pull ? (
        <Link
          href={`https://github.com/firezone/firezone/pull/${pull}`}
          className="text-accent-500 underline hover:no-underline"
        >
          {`#${pull}`}
        </Link>
      ) : null}{" "}
      {children}
    </li>
  );
}
