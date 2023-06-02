import NextLink from "next/link";

export function Link({
  href,
  children,
  ...props
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <NextLink
      href={href}
      className="font-medium text-blue-600 dark:text-blue-500 hover:underline"
      {...props}
    >
      {children}
    </NextLink>
  );
}

export function Code({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <code className="px-1.5 py-0.5 bg-gray-100 dark:bg-gray-900 rounded-md text-sm font-mono text-gray-900 dark:text-gray-100">
      {children}
    </code>
  );
}

export function UL({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <ul className="space-y-1 list-disc mb-4 list-inside" {...props}>
      {children}
    </ul>
  );
}

export function OL({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <ol className="space-y-1 list-decimal mb-4 list-inside" {...props}>
      {children}
    </ol>
  );
}

export function P({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <p className="mb-4" {...props}>
      {children}
    </p>
  );
}

export function H1({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h1
      className="mb-8 text-4xl font-extrabold leading-none tracking-tight text-gray-900 md:text-5xl lg:text-6xl dark:text-white"
      {...props}
    >
      {children}
    </h1>
  );
}

export function H2({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h2
      className="text-3xl font-bold text-gray-900 dark:text-white mb-6"
      {...props}
    >
      {children}
    </h2>
  );
}

export function H3({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h3
      className="text-2xl font-bold text-gray-900 dark:text-white mb-6"
      {...props}
    >
      {children}
    </h3>
  );
}

export function H4({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h4
      className="text-xl font-bold text-gray-900 dark:text-white mb-6"
      {...props}
    >
      {children}
    </h4>
  );
}

export function H5({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h5
      className="text-lg font-bold text-gray-900 dark:text-white mb-6"
      {...props}
    >
      {children}
    </h5>
  );
}

export function H6({
  children,
  ...props
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h6
      className="text-md font-bold text-gray-900 dark:text-white mb-6"
      {...props}
    >
      {children}
    </h6>
  );
}
