export default function Custom500() {
  return (
    <section className="bg-white dark:bg-neutral-900">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-sm text-center">
          <h1 className="mb-4 text-7xl tracking-tight font-extrabold lg:text-9xl text-primary-900 dark:text-primary-100">
            500
          </h1>
          <p className="mb-4 text-3xl tracking-tight font-bold text-neutral-900 md:text-4xl dark:text-white">
            Internal Server Error.
          </p>
          <p className="mb-4 text-lg font-light text-neutral-800 dark:text-neutral-100">
            We are already working to solve the problem.
          </p>
        </div>
      </div>
    </section>
  );
}
