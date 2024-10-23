export default function FeatureSection({
  reverse = false,
  title,
  titleCaption,
  description,
  image,
  cta,
}: {
  reverse?: boolean;
  title: React.ReactNode;
  titleCaption: string;
  description: React.ReactNode;
  image: React.ReactNode;
  cta: React.ReactNode;
}) {
  const copy = (
    <div className="mx-auto flex flex-col items-center lg:items-start text-center lg:text-left p-4 min-w-[320px] max-w-[700px] lg:max-w-[480px]">
      <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2">
        {titleCaption}
      </h6>
      <h3 className="mb-4 text-center lg:text-left text-3xl md:text-4xl lg:text-5xl leading-tight text-pretty tracking-tight font-bold inline-block">
        {title}
      </h3>
      {description}
      <div className="mt-6">{cta}</div>
    </div>
  );
  const graphic = (
    <div className="mx-auto p-4 min-w-[320px] max-w-[480px]">{image}</div>
  );

  return (
    <section className="py-16">
      <div
        className={`max-w-screen-xl mx-auto flex justify-between lg:flex-row items-center ${
          reverse ? "flex-col-reverse" : "flex-col"
        }`}
      >
        {reverse ? graphic : copy}
        {reverse ? copy : graphic}
      </div>
    </section>
  );
}
