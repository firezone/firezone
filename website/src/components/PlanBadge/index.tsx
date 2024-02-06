function planBadge(plan: string) {
  switch (plan.toLowerCase()) {
    case "enterprise":
      return (
        <span
          className="bg-primary-500 text-white text-xs font-semibold me-2 px-2.5 py-0.5 rounded"
          title="Feature available on the Enterprise plan"
        >
          ENTERPRISE
        </span>
      );
    case "starter":
      return (
        <span
          className="bg-neutral-200 text-neutral-900 text-xs font-semibold me-2 px-2.5 py-0.5 rounded"
          title="Feature available on the Starter plan"
        >
          STARTER
        </span>
      );
  }
}
export default function PlanBadge({ plans }: { plans: Array<string> }) {
  const plansHtml = plans.map((plan) => planBadge(plan));
  return <div className="mb-8">{plansHtml}</div>;
}
