import Image from "next/image";

export default function Post({
  authorName,
  authorTitle,
  authorAvatarSrc,
  title,
  date,
  children,
}: {
  authorName: string;
  authorTitle: string;
  authorAvatarSrc: string;
  title: string;
  date: string;
  children: React.ReactNode;
}) {
  return (
    <main className="py-14 lg:pb-24 border border-b ">
      <div className="flex justify-between px-4 mx-auto max-w-screen-xl">
        <article className="mx-auto w-full max-w-3xl tracking-[-0.01em] text-neutral-800 format format-sm md:format-md lg:format-lg format-firezone">
          <header className="mb-4 lg:mb-6 not-format">
            <address className="flex items-center mb-6 not-italic">
              <div className="inline-flex items-center mr-3 text-sm ">
                <Image
                  width={64}
                  height={64}
                  className="mr-4 w-16 h-16 rounded-full"
                  src={authorAvatarSrc}
                  alt={authorName}
                />
                <div>
                  <a href="#" rel="author" className="text-xl font-bold">
                    {authorName}
                  </a>
                  <p className="text-base">{authorTitle}</p>
                  <p className="text-base">
                    <time dateTime={date}>{date}</time>
                  </p>
                </div>
              </div>
            </address>
            <h1 className="mb-4 text-3xl font-bold leading-none tracking-tight lg:mb-6 lg:text-5xl ">
              {title}
            </h1>
          </header>
          <div className="pt-4">{children}</div>
        </article>
      </div>
    </main>
  );
}
