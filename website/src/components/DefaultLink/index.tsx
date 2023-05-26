import Link from "next/link";

export default function DefaultLink({
  href,
  children,
  ...props
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="font-medium text-blue-600 dark:text-blue-500 hover:underline"
      {...props}
    >
      {children}
    </Link>
  );
}
