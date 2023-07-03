import NewsletterSignup from "@/components/NewsletterSignup";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      {children}
      <div className="border-t border-neutral-200 dark:border-neutral-700 pt-8">
        <NewsletterSignup />
      </div>
    </div>
  );
}
