/*
 * Game Mode Scheduler - Dynamic thread affinity and priority management
 * Optimizes CPU scheduling for high-performance mobile gaming
 */

#include <linux/module.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/cpumask.h>
#include <linux/sysfs.h>
#include <linux/kthread.h>
#include <linux/spinlock.h>

#define GAMING_COMM_PATTERNS 10
#define GAMING_PID_POOL 64

/* Gaming-related process name patterns */
static const char *gaming_patterns[GAMING_COMM_PATTERNS] = {
	"com.tencent.ig",        /* PUBG Mobile */
	"com.pubg.krmobile",     /* PUBG: Battlegrounds */
	"com.pubg.imobile",      /* BGMI */
	"com.tencent.tmgp",      /* Tencent Gaming */
	"renderer",              /* Game render thread */
	"main",                  /* Game main thread */
	"Skia",                  /* Graphics framework */
	"InputDispatcher",       /* Input handling */
	"RenderThread",          /* Render thread */
	"GameThread"             /* Generic game thread */
};

struct game_process {
	pid_t pid;
	cpumask_t perf_cpumask;  /* Performance cores (Gold cluster) */
	int priority;
	bool is_game;
	struct list_head list;
	spinlock_t lock;
};

static DEFINE_SPINLOCK(game_processes_lock);
static LIST_HEAD(game_processes);

/* Performance cores on SM8250: 0x0C0 = cores 6,7 (Gold cluster) */
#define PERF_CORES_MASK 0x0C0

/* Gaming mode enabled flag */
static atomic_t gaming_mode_enabled = ATOMIC_INIT(1);

/**
 * detect_gaming_process - Identify if a process is game-related
 */
static bool detect_gaming_process(const char *comm)
{
	int i;
	if (!comm)
		return false;

	for (i = 0; i < GAMING_COMM_PATTERNS; i++) {
		if (strstr(comm, gaming_patterns[i]) != NULL)
			return true;
	}
	return false;
}

/**
 * set_game_affinity - Pin game threads to performance cores
 */
static int set_game_affinity(struct task_struct *p, cpumask_t *mask)
{
	cpumask_var_t new_mask;
	int ret;

	if (!alloc_cpumask_var(&new_mask, GFP_KERNEL))
		return -ENOMEM;

	cpumask_copy(new_mask, mask);

	/* Set affinity to performance cores only */
	ret = __set_cpus_allowed_ptr(p, new_mask, SCA_MIGRATE_ENABLE);

	free_cpumask_var(new_mask);
	return ret;
}

/**
 * boost_game_priority - Increase game thread priority
 */
static void boost_game_priority(struct task_struct *p)
{
	struct sched_param param;

	if (!p)
		return;

	/* Set to high priority but not real-time to avoid system issues */
	param.sched_priority = -5;  /* Higher priority in CFS */
	sched_setattr_nocheck(p, &param);
}

/**
 * register_game_process - Register a new game process
 */
int register_game_process(pid_t pid)
{
	struct game_process *gp;
	struct task_struct *p;
	cpumask_var_t perf_mask;
	unsigned long flags;

	if (!atomic_read(&gaming_mode_enabled))
		return -EINVAL;

	p = find_task_by_vpid(pid);
	if (!p)
		return -ESRCH;

	gp = kzalloc(sizeof(*gp), GFP_KERNEL);
	if (!gp)
		return -ENOMEM;

	if (!alloc_cpumask_var(&perf_mask, GFP_KERNEL)) {
		kfree(gp);
		return -ENOMEM;
	}

	/* Initialize performance core mask (Gold cluster) */
	cpumask_clear(perf_mask);
	cpumask_set_cpu(6, perf_mask);  /* Gold core 0 */
	cpumask_set_cpu(7, perf_mask);  /* Gold core 1 */

	gp->pid = pid;
	cpumask_copy(&gp->perf_cpumask, perf_mask);
	gp->is_game = true;
	gp->priority = 5;

	/* Apply affinity and boost priority */
	set_game_affinity(p, perf_mask);
	boost_game_priority(p);

	spin_lock_irqsave(&game_processes_lock, flags);
	list_add_tail(&gp->list, &game_processes);
	spin_unlock_irqrestore(&game_processes_lock, flags);

	free_cpumask_var(perf_mask);
	return 0;
}
EXPORT_SYMBOL_GPL(register_game_process);

/**
 * unregister_game_process - Unregister a game process
 */
int unregister_game_process(pid_t pid)
{
	struct game_process *gp, *tmp;
	unsigned long flags;

	spin_lock_irqsave(&game_processes_lock, flags);
	list_for_each_entry_safe(gp, tmp, &game_processes, list) {
		if (gp->pid == pid) {
			list_del(&gp->list);
			spin_unlock_irqrestore(&game_processes_lock, flags);
			kfree(gp);
			return 0;
		}
	}
	spin_unlock_irqrestore(&game_processes_lock, flags);
	return -ESRCH;
}
EXPORT_SYMBOL_GPL(unregister_game_process);

/**
 * gaming_mode_show - Show gaming mode status
 */
static ssize_t gaming_mode_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%d\n",
			atomic_read(&gaming_mode_enabled));
}

/**
 * gaming_mode_store - Enable/disable gaming mode
 */
static ssize_t gaming_mode_store(struct kobject *kobj,
				  struct kobj_attribute *attr,
				  const char *buf, size_t count)
{
	int enabled;

	if (sscanf(buf, "%d", &enabled) != 1)
		return -EINVAL;

	atomic_set(&gaming_mode_enabled, !!enabled);
	return count;
}

static struct kobj_attribute gaming_mode_attr =
	__ATTR(enabled, 0644, gaming_mode_show, gaming_mode_store);

static struct attribute *game_sysfs_attrs[] = {
	&gaming_mode_attr.attr,
	NULL
};

static const struct attribute_group game_sysfs_group = {
	.attrs = game_sysfs_attrs,
};

/**
 * game_mode_init - Initialize game mode subsystem
 */
static int __init game_mode_init(void)
{
	int ret;
	struct kobject *kobj;

	kobj = kobject_create_and_add("gamemode", kernel_kobj);
	if (!kobj) {
		pr_err("Failed to create gamemode kobject\n");
		return -ENOMEM;
	}

	ret = sysfs_create_group(kobj, &game_sysfs_group);
	if (ret) {
		pr_err("Failed to create gamemode sysfs group\n");
		kobject_put(kobj);
		return ret;
	}

	pr_info("Game Mode scheduler initialized\n");
	return 0;
}

module_init(game_mode_init);

MODULE_AUTHOR("Gaming Optimization Team");
MODULE_DESCRIPTION("Game Mode Scheduler - Core affinity and priority management");
MODULE_LICENSE("GPL");
