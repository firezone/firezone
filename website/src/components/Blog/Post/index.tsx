import Image from "next/image";
import gravatar from "@/lib/gravatar";

export default function Post({
  authorName,
  authorTitle,
  authorEmail,
  title,
  date,
  children,
}: {
  authorName: string;
  authorTitle: string;
  authorEmail: string;
  title: string;
  date: string;
  children: React.ReactNode;
}) {
  return (
    <main className="py-14 lg:pb-24 border border-b-1 ">
      <div className="flex justify-between px-4 mx-auto max-w-screen-xl">
        <article className="mx-auto w-full max-w-2xl format format-lg text-neutral-900">
          <header className="mb-4 lg:mb-6 not-format">
            <address className="flex items-center mb-6 not-italic">
              <div className="inline-flex items-center mr-3 text-sm text-neutral-900 ">
                <Image
                  width={64}
                  height={64}
                  className="mr-4 w-16 h-16 rounded-full"
                  src={gravatar(authorEmail)}
                  alt={authorName}
                />
                <div>
                  <a
                    href="#"
                    rel="author"
                    className="text-xl font-bold text-neutral-900"
                  >
                    {authorName}
                  </a>
                  <p className="text-base text-neutral-900 ">{authorTitle}</p>
                  <p className="text-base text-neutral-900 ">
                    <time dateTime={date}>{date}</time>
                  </p>
                </div>
              </div>
            </address>
            <h1 className="mb-4 text-3xl font-bold leading-none tracking-tight text-neutral-900 lg:mb-6 lg:text-5xl ">
              {title}
            </h1>
          </header>
          <div className="pt-4">{children}</div>
        </article>
      </div>
    </main>
  );
}
