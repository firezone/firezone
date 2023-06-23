import NewsletterSignup from "@/components/NewsletterSignup";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-24 flex flex-col">
      {children}
      <div className="border-t border-gray-200 dark:border-gray-700 pt-8">
        <NewsletterSignup />
      </div>
    </div>
  );
}
